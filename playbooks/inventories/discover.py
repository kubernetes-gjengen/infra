#!/usr/bin/env python3
"""Ansible dynamic inventory: discover Raspberry Pis on the wired setup LAN.

The cluster has no written-down inventory. On every run this script ARP-scans
the setup subnet, keeps hosts whose MAC OUI belongs to a Raspberry Pi, and
splits them into two groups:

  * manager - exactly one node. The first Raspberry Pi 5 found (its OUI is in
    PI5_OUIS); if there is no Pi 5, the lowest-IP Pi is promoted instead.
    Sticky: once a MAC is manager, it stays manager across runs as long as
    it's still on the network, even if a Pi 5 joins later.
  * worker  - every other Pi.

Hostnames (manager0, worker0, worker1, ...) are keyed by MAC address and
persisted across runs in STATE_PATH (discovered_hosts.json, next to this
script). A MAC keeps its hostname forever once assigned, even if its IP
changes or other Pis join/leave/reorder - only a MAC seen for the first time
gets a newly minted name. This matters because k3s node identity and mDNS
records are keyed off the hostname; renumbering it out from under an
already-provisioned node leaves stale/duplicate state behind. Offline Pis
keep their reserved slot (and worker-number) so it can't be reused by a
different physical Pi later - they just don't appear in the inventory output
until they're seen again. The state file is local, per-cluster machine
state, not repo content - it's gitignored.

Mesh IPs are deliberately NOT set here. Workers lease their bat0 address from
the manager's DHCP server (dnsmasq), and the manager's fixed bat0 address lives
in group_vars/all.yml as `manager_mesh_ip`. The only address this script deals
with is the wired setup IP used to SSH in (ansible_host).

Usage (invoked by Ansible):
    discover.py --list
    discover.py --host <name>

Requires passwordless `sudo nmap` on the provisioner (ARP scanning needs root).
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
    """Persist MAC -> hostname assignments. Best-effort: a write failure
    (e.g. read-only filesystem) shouldn't break inventory generation, it
    just means names may be re-derived next run instead of staying pinned.
    """
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
        # No manager yet, or the old one is offline - pick a new one with
        # the original rule (prefer Pi 5, else lowest IP) among live Pis.
        manager_mac = next(
            (mac for _, mac in pis if mac.startswith(PI5_OUIS)),
            pis[0][1] if pis else None,
        )
        if old_manager_mac is not None:
            # Free its slot rather than leaving two MACs pointing at
            # "manager0" - if it comes back it'll be treated as a new,
            # unnamed Pi and given the next free workerN.
            del assignments[old_manager_mac]

    if manager_mac is not None:
        assignments[manager_mac] = "manager0"

    # Never reuse a workerN that's already claimed, even by a currently
    # offline Pi - each physical Pi keeps its number for good.
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
        # A Pi can answer ARP on more than one IP at once (e.g. a stale DHCP
        # lease that never got released alongside a fresh one). Collapse to
        # one entry per MAC so it isn't counted as two separate nodes; keep
        # the lowest IP for determinism.
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
    pis.sort(key=lambda pi: tuple(int(octet) for octet in pi[0].split(".")))
    return pis


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

    for ip, mac in pis:
        name = assignments[mac]
        group = "manager" if name == "manager0" else "worker"
        inventory[group]["hosts"].append(name)

        inventory["_meta"]["hostvars"][name] = {
            "ansible_host": ip,
            "ansible_user": SSH_USER,
            "ansible_password": SSH_PASSWORD,
            "ansible_become_pass": SSH_PASSWORD,
            "pi_hostname": name,
        }

    return inventory


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--list", action="store_true", help="emit the full inventory")
    parser.add_argument("--host", help="emit vars for one host (unused; see _meta)")
    args = parser.parse_args()

    if args.host:
        # All hostvars are published via _meta, so per-host lookups are empty.
        print(json.dumps({}))
    else:
        print(json.dumps(build_inventory(), indent=2))


if __name__ == "__main__":
    main()
