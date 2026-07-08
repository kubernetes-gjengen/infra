# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this project does

This repo automates the setup of a **MANET (Mobile Ad-hoc NETwork)** using the [B.A.T.M.A.N. (batman-adv)](https://www.open-mesh.org/projects/batman-adv/wiki/Using-batctl) mesh routing protocol on a Raspberry Pi cluster. Ansible provisions the nodes; shell scripts configure the mesh and bridge interfaces at runtime.

## Running the playbook

```bash
# From the playbooks/ directory. Discovers Pis on the LAN and provisions them.
ansible-playbook provision_all.yml

# Target a subset (names are manager0 / worker0 / worker1 … from discovery)
ansible-playbook provision_all.yml --limit worker0
```

`playbooks/ansible.cfg` sets `inventories/discover.py` as the default inventory,
so no `-i` flag is needed when running from `playbooks/`.

## Architecture

### Provisioning flow (`config-batman.yml`)

1. **All nodes** — installs `batctl`, copies and runs `config_batman.sh <mesh_ip>` where the IP is derived as `192.168.3.<base_ip_start + node_index>` (base `241`).
2. **Manager node only** — copies and runs `bridge.sh`, bridging `bat0` (mesh) and `eth0` (ethernet) into `br0` so the operator's laptop can reach all mesh nodes via a single ethernet connection.

### Inventory

- `inventories/discover.py` — **dynamic inventory** (the default). ARP-scans the wired setup subnet (`192.168.3.0/24`), keeps hosts with a Raspberry Pi MAC OUI, and splits them into `manager` (first Pi 5 found, else lowest-IP Pi) and `worker` groups. Hostnames (`manager0`, `worker0`, …) are re-numbered by IP on every run — no persisted state. Requires passwordless `sudo nmap` on the provisioner.
- Mesh IPs are **not** in inventory: workers lease their `bat0` address from the manager's DHCP server, and the manager's fixed `bat0` address is `manager_mesh_ip` in `group_vars/all.yml` (`192.168.42.1`).
- `inventories/static-eth.ini` / `static-bat.ini` — legacy static inventories, kept for reference / manual runs (`-i inventories/static-eth.ini`).

### Shell scripts

| Script | Runs on | Purpose |
|---|---|---|
| `config_batman.sh <mesh_ip>` | Each Pi | Stops NetworkManager/wpa_supplicant, puts `wlan0` in ad-hoc mode on SSID `meshnet` channel 1, loads `batman-adv`, assigns mesh IP to `bat0`, adds default route via `192.168.3.241` |
| `bridge.sh` | Manager Pi | Bridges `eth0` + `bat0` into `br0`, preserving both IP addresses |
| `network_prober.sh` | Each Pi | Measures per-neighbour latency and throughput via `batctl`, then pushes results to a gRPC `LinkService` (port-forwarded from a K8s pod) |
| `network_probe_runner.sh` | Each Pi | Wrapper that runs `network_prober.sh` in a loop with random 10–120 s backoff |

### Systemd services

- `batman.service` — reads IP from `/home/pi/ip_addr` and runs `config_batman.sh` on boot. **Must be installed and the `ip_addr` file created manually** (not done by the playbook).
- `network_prober.service` — runs `network_probe_runner.sh` continuously via `Restart=always`.

### Network topology

```
Laptop ── eth0 ── [Manager Pi (br0: eth0 + bat0)] ── batman-adv mesh ── Worker Pis
                   192.168.3.241/28                    192.168.3.241–245/28
```

The `/28` subnet covers `.241–.254` (14 addresses); default route for all mesh nodes points to the manager (`192.168.3.241`).

### Kubernetes / registry

`registry/registry.yml` deploys a Docker registry (`registry:2`) as a K8s Deployment + NodePort service on port `30500`, backed by a 5 Gi PVC using `local-path` storage class.

## Known manual steps (not automated)

- Copy `batman.service` to `/etc/systemd/system/` on each Pi and run `sudo systemctl enable batman`.
- Create `/home/pi/ip_addr` on each Pi containing its desired mesh IP.
- The `network_prober.sh` expects a `message.proto` at `/home/pi/` and a running `apiserver` pod in K8s with port `50051`.
