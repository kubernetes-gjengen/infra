#!/usr/bin/env python3
"""Ansible dynamic inventory: discover Raspberry Pis on the wired setup LAN.

The cluster has no written-down inventory. On every run this script ARP-scans
the setup subnet, keeps hosts whose MAC OUI belongs to a Raspberry Pi, and
splits them into two groups:

  * manager - exactly one node. The first Raspberry Pi 5 found (its OUI is in
    PI5_OUIS); if there is no Pi 5, the lowest-IP Pi is promoted instead.
  * worker  - every other Pi.

Hostnames (manager0, worker0, worker1, ...) are assigned by ascending IP and
are therefore re-numbered on every scan - there is no persisted state.

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

# Wired subnet the Pis boot onto before the mesh exists.
SCAN_SUBNET = "192.168.3.0/24"

# Raspberry Pi MAC OUI prefixes (same set absorb.py filters DHCP traffic on).
PI_OUIS = ("28:cd:c1", "b8:27:eb", "d8:3a:dd", "dc:a6:32", "e4:5f:01")
# Pi 5 OUIs - preferred as the manager, since the Pi 5 is the beefy node.
PI5_OUIS = ("d8:3a:dd", "e4:5f:01")

SSH_USER = "pi"
SSH_PASSWORD = "raspberry"


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

    pis = []
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
        if ip and mac and mac.startswith(PI_OUIS):
            pis.append((ip, mac))

    pis.sort(key=lambda pi: tuple(int(octet) for octet in pi[0].split(".")))
    return pis


def build_inventory():
    """Turn the scan result into an Ansible JSON inventory."""
    pis = scan_pis()

    # Manager = first Pi 5 by IP order, else the lowest-IP Pi.
    manager_idx = next(
        (i for i, (_, mac) in enumerate(pis) if mac.startswith(PI5_OUIS)),
        0 if pis else None,
    )

    inventory = {
        "manager": {"hosts": []},
        "worker": {"hosts": []},
        "_meta": {"hostvars": {}},
    }

    worker_n = 0
    for i, (ip, _mac) in enumerate(pis):
        if i == manager_idx:
            name = "manager0"
            inventory["manager"]["hosts"].append(name)
        else:
            name = f"worker{worker_n}"
            worker_n += 1
            inventory["worker"]["hosts"].append(name)

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
