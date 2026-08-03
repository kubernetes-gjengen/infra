#!/usr/bin/env python3
"""Ansible dynamic inventory: discover Raspberry Pis on the wired setup LAN.

ARP-scans the setup subnet each run, keeps Pi-OUI hosts, splits into groups:
  * manager - one node. Prefers a Pi 5 (PI5_OUIS), else lowest IP. Sticky:
    stays manager across runs while online, even if a Pi 5 joins later.
  * worker  - every other Pi.

Hostnames (manager0, worker0, ...) are keyed by MAC and persisted in
STATE_PATH (discovered_hosts.json, gitignored, local machine state). A MAC
keeps its name forever once assigned - k3s node identity/mDNS key off it, so
renumbering would leave stale state. Offline Pis keep their slot so it can't
be reused by another physical Pi; they just drop out of the output till seen
again.

Mesh IPs aren't set here - workers DHCP-lease bat0 from the manager, whose
fixed bat0 IP is `manager_mesh_ip` in group_vars/all.yml. Only the wired
setup IP (ansible_host) is handled here.

A Pi that misses the wired scan but was previously assigned isn't dropped as
long as the manager is still wired: it's reached over the mesh instead via
`ssh -W`, proxied through the manager. ansible_host becomes `<name>.gotham` -
the manager resolves that name itself, so this script never needs the node's
DHCP-leased bat0 address.

Usage (invoked by Ansible): discover.py --list / discover.py --host <name>
Requires passwordless `sudo nmap` on the provisioner.
"""
import argparse
import json
import subprocess
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

# Wired subnet the Pis boot onto before the mesh exists.
SCAN_SUBNET = "192.168.3.0/24"

# Raspberry Pi MAC OUI prefixes (same set absorb.py filters DHCP traffic on).
PI_OUIS = ("28:cd:c1", "b8:27:eb", "d8:3a:dd", "dc:a6:32", "e4:5f:01")
# Pi 5 OUIs - preferred as the manager, since the Pi 5 is the beefy node.
PI5_OUIS = ("d8:3a:dd", "e4:5f:01")

SSH_USER = "pi"
SSH_PASSWORD = "raspberry"

# Persisted MAC -> hostname assignments. Resolved relative to this file (not
# cwd) so it works the same regardless of where ansible invokes the script
# from.
STATE_PATH = Path(__file__).resolve().parent / "discovered_hosts.json"


def load_assignments():
    """Load persisted MAC -> hostname assignments. Missing/corrupt -> empty."""
    try:
        with open(STATE_PATH) as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return {}


def save_assignments(assignments):
    """Persist MAC -> hostname assignments. Best-effort: write failure
    shouldn't break inventory generation, just means names may re-derive."""
    try:
        with open(STATE_PATH, "w") as f:
            json.dump(assignments, f, indent=2, sort_keys=True)
            f.write("\n")
    except OSError as exc:
        print(f"discover.py: could not persist hostnames: {exc}", file=sys.stderr)


def assign_hostnames(pis, assignments):
    """Extend a MAC -> hostname map with any not-yet-seen MACs from `pis`
    (a list of (ip, mac) sorted by ascending IP), and pin the manager.

    Mutates and returns `assignments`. Existing entries are never renamed.
    """
    live_macs = {mac for _, mac in pis}

    old_manager_mac = next(
        (mac for mac, name in assignments.items() if name == "manager0"), None
    )
    if old_manager_mac in live_macs:
        manager_mac = old_manager_mac
    else:
        # No manager, or old one offline - pick new one (prefer Pi 5, else lowest IP).
        manager_mac = next(
            (mac for _, mac in pis if mac.startswith(PI5_OUIS)),
            pis[0][1] if pis else None,
        )
        if old_manager_mac is not None:
            # Free the slot; old manager gets a fresh workerN if it returns.
            del assignments[old_manager_mac]

    if manager_mac is not None:
        assignments[manager_mac] = "manager0"

    # Never reuse a claimed workerN, even from an offline Pi - numbers stick for good.
    used_worker_ns = {
        int(name[len("worker") :])
        for name in assignments.values()
        if name.startswith("worker")
    }
    next_worker_n = max(used_worker_ns, default=-1) + 1
    for _, mac in pis:
        if mac != manager_mac and mac not in assignments:
            assignments[mac] = f"worker{next_worker_n}"
            next_worker_n += 1

    return assignments


def local_pi_entry():
    """(ip, mac) for eth0 if this script is itself running on a Pi wired
    into SCAN_SUBNET - None otherwise (e.g. running from a laptop).

    A host never receives its own ARP reply, so scan_pis() alone can never
    see the Pi it's actually running on. Harmless when run from the
    manager's own venividivici pod for every *other* node, but without this
    the manager's own MAC always looks "offline" to itself: sticky-manager
    logic in assign_hostnames() then deletes its assignment and promotes a
    different Pi to manager0 on every single run.
    """
    try:
        mac = Path("/sys/class/net/eth0/address").read_text().strip().lower()
    except OSError:
        return None
    if not mac.startswith(PI_OUIS):
        return None
    try:
        out = subprocess.run(
            ["ip", "-4", "-o", "addr", "show", "eth0"],
            capture_output=True, text=True, check=True,
        ).stdout
    except (subprocess.CalledProcessError, FileNotFoundError):
        return None
    tokens = out.split()
    if "inet" not in tokens:
        return None
    ip = tokens[tokens.index("inet") + 1].split("/")[0]
    if not ip.startswith(SCAN_SUBNET.rsplit(".", 1)[0] + "."):
        return None
    return ip, mac


def scan_pis():
    """ARP-scan the setup subnet; return [(ip, mac), ...] for Raspberry Pis.

    Sorted by ascending numeric IP so hostname assignment is deterministic.
    Returns an empty list (rather than raising) if nmap is missing or fails,
    so `ansible-inventory --list` degrades gracefully.
    """
    try:
        out = subprocess.run(
            ["sudo", "nmap", "-sn", "-PR", SCAN_SUBNET, "-oX", "-"],
            capture_output=True,
            text=True,
            check=True,
        ).stdout
    except (subprocess.CalledProcessError, FileNotFoundError) as exc:
        print(f"discover.py: nmap scan failed: {exc}", file=sys.stderr)
        return []

    by_mac = {}
    for host in ET.fromstring(out).findall("host"):
        status = host.find("status")
        if status is None or status.get("state") != "up":
            continue
        ip = mac = None
        for addr in host.findall("address"):
            if addr.get("addrtype") == "ipv4":
                ip = addr.get("addr")
            elif addr.get("addrtype") == "mac":
                mac = (addr.get("addr") or "").lower()
        if not (ip and mac and mac.startswith(PI_OUIS)):
            continue
        ip_key = tuple(int(octet) for octet in ip.split("."))
        # A Pi can answer ARP on >1 IP (stale + fresh DHCP lease). Collapse
        # to one entry per MAC, keeping the lowest IP for determinism.
        existing = by_mac.get(mac)
        if existing is not None:
            kept = ip if ip_key < existing[0] else existing[1]
            print(
                f"discover.py: {mac} has multiple live IPs "
                f"({existing[1]}, {ip}); using {kept}",
                file=sys.stderr,
            )
        if existing is None or ip_key < existing[0]:
            by_mac[mac] = (ip_key, ip)

    pis = [(ip, mac) for mac, (_, ip) in by_mac.items()]

    local = local_pi_entry()
    if local is not None and local[1] not in by_mac:
        pis.append(local)

    pis.sort(key=lambda pi: tuple(int(octet) for octet in pi[0].split(".")))
    return pis


def mesh_proxy_extra_ssh_args(manager_wired_ip):
    """-o ProxyCommand=... args (list form, no outer shell quoting) to reach
    a mesh-only Pi through the manager, mirroring mesh_proxy_ssh_args."""
    return [
        "-o",
        "ProxyCommand=sshpass -p {password} ssh -o StrictHostKeyChecking=no "
        "-o UserKnownHostsFile=/dev/null -W %h:%p {user}@{manager_ip}".format(
            password=SSH_PASSWORD, user=SSH_USER, manager_ip=manager_wired_ip
        ),
    ]


def fetch_model(target, extra_ssh_args=None, timeout=5):
    """SSH into `target` and read the Pi model string. None on any failure.

    Manual-only (--model): never called from --list / the ansible flow.
    """
    cmd = [
        "sshpass", "-p", SSH_PASSWORD,
        "ssh", "-o", "StrictHostKeyChecking=no",
        "-o", "UserKnownHostsFile=/dev/null",
        "-o", f"ConnectTimeout={timeout}",
        *(extra_ssh_args or []),
        f"{SSH_USER}@{target}", "cat /proc/device-tree/model",
    ]
    try:
        out = subprocess.run(
            cmd, capture_output=True, text=True, timeout=timeout + 5,
        )
    except (subprocess.TimeoutExpired, FileNotFoundError):
        return None
    if out.returncode != 0:
        return None
    return out.stdout.strip("\x00\n")


def print_models():
    """Manual-only: SSH each Pi (wired direct, mesh-only proxied through the
    manager) and print name/ip/mac/model as a table."""
    pis = scan_pis()
    assignments = assign_hostnames(pis, load_assignments())
    save_assignments(assignments)

    wired_ip_by_mac = {mac: ip for ip, mac in pis}
    manager_mac = next(
        (mac for mac, name in assignments.items() if name == "manager0"), None
    )
    manager_wired_ip = wired_ip_by_mac.get(manager_mac)

    rows = []
    for mac, name in sorted(assignments.items(), key=lambda item: item[1]):
        wired_ip = wired_ip_by_mac.get(mac)
        if wired_ip is not None:
            target, extra_args, shown_ip = wired_ip, None, wired_ip
        elif manager_wired_ip is not None and mac != manager_mac:
            target = f"{name}.gotham"
            extra_args = mesh_proxy_extra_ssh_args(manager_wired_ip)
            shown_ip = target
        else:
            rows.append((name, "(offline)", mac, "-"))
            continue
        model = fetch_model(target, extra_args) or "(unreachable)"
        rows.append((name, shown_ip, mac, model))

    widths = [max(len(row[i]) for row in rows) if rows else 0 for i in range(4)]
    for name, ip, mac, model in rows:
        print(f"{name:<{widths[0]}}  {ip:<{widths[1]}}  {mac:<{widths[2]}}  {model}")


def mesh_proxy_ssh_args(manager_wired_ip):
    """ansible_ssh_common_args that tunnel through the manager's wired IP.

    Password auth (SSH_PASSWORD) has to be supplied a second time here for
    the jump hop itself - ansible_password only covers the final leg, and
    there's no key-based auth set up on these Pis to fall back on.
    """
    return (
        "-o StrictHostKeyChecking=no "
        "-o ProxyCommand=\"sshpass -p {password} ssh -o StrictHostKeyChecking=no "
        "-o UserKnownHostsFile=/dev/null -W %h:%p {user}@{manager_ip}\""
    ).format(password=SSH_PASSWORD, user=SSH_USER, manager_ip=manager_wired_ip)


def build_inventory():
    """Turn the scan result into an Ansible JSON inventory."""
    pis = scan_pis()

    assignments = assign_hostnames(pis, load_assignments())
    save_assignments(assignments)

    inventory = {
        "manager": {"hosts": []},
        "worker": {"hosts": []},
        "_meta": {"hostvars": {}},
    }

    wired_ip_by_mac = {mac: ip for ip, mac in pis}
    manager_mac = next(
        (mac for mac, name in assignments.items() if name == "manager0"), None
    )
    manager_wired_ip = wired_ip_by_mac.get(manager_mac)

    for mac, name in sorted(assignments.items(), key=lambda item: item[1]):
        wired_ip = wired_ip_by_mac.get(mac)

        if wired_ip is not None:
            hostvars = {
                "ansible_host": wired_ip,
                "ansible_user": SSH_USER,
                "ansible_password": SSH_PASSWORD,
                "ansible_become_pass": SSH_PASSWORD,
                "pi_hostname": name,
            }
        elif manager_wired_ip is not None and mac != manager_mac:
            # Off wired LAN, manager up - reach over mesh, proxied through manager.
            hostvars = {
                "ansible_host": f"{name}.gotham",
                "ansible_user": SSH_USER,
                "ansible_password": SSH_PASSWORD,
                "ansible_become_pass": SSH_PASSWORD,
                "ansible_ssh_common_args": mesh_proxy_ssh_args(manager_wired_ip),
                "pi_hostname": name,
            }
        else:
            # No wired IP, no manager to proxy through - stays out of inventory.
            continue

        group = "manager" if name == "manager0" else "worker"
        inventory[group]["hosts"].append(name)
        inventory["_meta"]["hostvars"][name] = hostvars

    return inventory


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--list", action="store_true", help="emit the full inventory")
    parser.add_argument("--host", help="emit vars for one host (unused; see _meta)")
    parser.add_argument(
        "--model", action="store_true",
        help="manual-only: SSH each wired Pi and print its model (not used by ansible)",
    )
    args = parser.parse_args()

    if args.model:
        print_models()
    elif args.host:
        # All hostvars are published via _meta, so per-host lookups are empty.
        print(json.dumps({}))
    else:
        print(json.dumps(build_inventory(), indent=2))


if __name__ == "__main__":
    main()
