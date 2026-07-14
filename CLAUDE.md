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

- `inventories/discover.py` — **dynamic inventory** (the default). ARP-scans the wired setup subnet (`192.168.3.0/24`), keeps hosts with a Raspberry Pi MAC OUI, and splits them into `manager` (first Pi 5 found, else lowest-IP Pi) and `worker` groups. Hostnames (`manager0`, `worker0`, …) are keyed by MAC and persisted in `inventories/discovered_hosts.json` (gitignored, local machine state) — a MAC keeps its name forever once assigned, even as IPs change or other Pis join/leave/reorder; only a never-before-seen MAC gets a new name. The manager role is sticky the same way (won't jump to a newly joined Pi 5) and is only re-picked if the current manager MAC goes offline. Requires passwordless `sudo nmap` on the provisioner. A previously-assigned Pi that misses the wired scan (unplugged, or mesh-only) isn't dropped as long as the manager is still wired: it's included with `ansible_host` set to `<name>.gotham` and `ansible_ssh_common_args` set to a `ProxyCommand` that tunnels through the manager's wired IP — the manager resolves `<name>.gotham` itself (its resolver points at its own dnsmasq), so the mesh IP is never looked up here.
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

`registry/zot.yml` deploys [Zot](https://zotregistry.dev) (an OCI-native registry with a web UI + CVE scanning, chosen over Harbor because Harbor's official images are amd64-only and don't run on the Pi cluster) as a K8s Deployment + NodePort service on port `30500`, pinned to the manager node, backed by a 5 Gi PVC using `local-path` storage class. Canonical address is `manager0.gotham:30500` — every image push/reference must use that exact string, since containerd's per-node TLS trust config keys off it unnormalized. TLS is a self-signed cert (`zot-tls` k8s secret, manually created); trusting its CA in every node's containerd is automated by `tasks/configure_registry_trust.yml` (part of `provision_all.yml`, reads the CA from `registry_ca_cert_path` in `group_vars/all.yml`, a controller-local file never committed to the repo). See `registry/README.md` for full setup.

## Known manual steps (not automated)

- Copy `batman.service` to `/etc/systemd/system/` on each Pi and run `sudo systemctl enable batman`.
- Create `/home/pi/ip_addr` on each Pi containing its desired mesh IP.
- The `network_prober.sh` expects a `message.proto` at `/home/pi/` and a running `apiserver` pod in K8s with port `50051`.
- Zot registry TLS: generate the cert and create the `zot-tls` k8s secret — see `registry/README.md`. (Trusting the CA on every node's containerd *is* automated, unlike the other items in this list.)
