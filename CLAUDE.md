# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this project does

This repo automates the setup of a **MANET (Mobile Ad-hoc NETwork)** using the [B.A.T.M.A.N. (batman-adv)](https://www.open-mesh.org/projects/batman-adv/wiki/Using-batctl) mesh routing protocol on a Raspberry Pi cluster. Ansible provisions the nodes and configures the mesh/netplan networking; shell scripts handle field-test logging and operator-facing tooling (live cluster views, GPS discovery) on top.

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

### Provisioning flow (`provision_all.yml`)

Idempotent, tag-scoped sequence of plays run against the dynamic inventory:

1. Hostname, avahi (mDNS), bashrc prompt, timezone, mesh-local NTP (chrony against manager0).
2. Mesh networking on every node (`tasks/00_configure_network_common.yml`): deploys `config_batman2_electric_boogaloo.sh` and a templated `batman.service` that bring up `wlan0` in ad-hoc mode and the `bat0` interface, plus a netplan profile (`templates/90-netplan-workers.yml.j2`) for `bat0`/`eth0`.
3. Manager only: NAT (iptables MASQUERADE from `bat0` out `eth0`) and `dnsmasq` DHCP/DNS on `bat0` handing out mesh IPs and `*.gotham` names.
4. k3s server on the manager, k3s agent on workers (joins over `manager0.gotham`).
5. Capability detection (GPS/AI camera/Sense HAT/Pi model, `capabilities.yml`) — labels k8s nodes `capability/<key>=true`.
6. Field-test logging (`fieldlog-resource.service`, installed disabled) and the network prober (`probe.yml` — a C binary cross-compiled from the sibling `prober/` repo, publishes latency/throughput to MQTT).
7. Registry CA trust for containerd (Zot).

### Inventory

- `inventories/discover.py` — **dynamic inventory** (the default). ARP-scans the wired setup subnet (`192.168.3.0/24`), keeps hosts with a Raspberry Pi MAC OUI, and splits them into `manager` (first Pi 5 found, else lowest-IP Pi) and `worker` groups. Hostnames (`manager0`, `worker0`, …) are keyed by MAC and persisted in `inventories/discovered_hosts.json` (gitignored, local machine state) — a MAC keeps its name forever once assigned, even as IPs change or other Pis join/leave/reorder; only a never-before-seen MAC gets a new name. The manager role is sticky the same way (won't jump to a newly joined Pi 5) and is only re-picked if the current manager MAC goes offline. Requires passwordless `sudo nmap` on the provisioner. A previously-assigned Pi that misses the wired scan (unplugged, or mesh-only) isn't dropped as long as the manager is still wired: it's included with `ansible_host` set to `<name>.gotham` and `ansible_ssh_common_args` set to a `ProxyCommand` that tunnels through the manager's wired IP — the manager resolves `<name>.gotham` itself (its resolver points at its own dnsmasq), so the mesh IP is never looked up here.
- Mesh IPs are **not** in inventory: workers lease their `bat0` address from the manager's DHCP server, and the manager's fixed `bat0` address is `manager_mesh_ip` in `group_vars/all.yml` (`192.168.42.1`).
- `inventories/static-eth.ini` / `static-bat.ini` — legacy static inventories, kept for reference / manual runs (`-i inventories/static-eth.ini`).

### Shell scripts

| Script | Runs on | Purpose |
|---|---|---|
| `config_batman2_electric_boogaloo.sh` | Each Pi | Stops NetworkManager/wpa_supplicant, puts `wlan0` in ad-hoc mode on SSID/channel from `MESH_SSID`/`MESH_CHANNEL`, loads `batman-adv`, brings up `bat0` — driven by `batman.service`, templated in by `tasks/00_configure_network_common.yml` |
| `fieldlog_resource.sh` | Each Pi | Field-test CPU/mem/disk sampler; installed disabled, toggled by `make start-logging`/`stop-logging` |
| `watchctl.sh` / `watch_links.sh` | Laptop (manual) | Live `watch`-style views into the cluster / live mesh link latency-throughput table sourced from MQTT |
| `deployctl.sh` | Laptop (manual) | `make deploy` — picks and runs a sibling repo's k8s Deployment target |
| `reset_known_hosts.sh` | Laptop (manual) | Clears stale SSH host keys after reflashing/reimaging a Pi |

Bridging (formerly `bridge.sh`, `eth0`+`bat0` into a `br0` on the manager) and the network prober (formerly `network_prober.sh`/`network_probe_runner.sh`, bash + gRPC) have since been replaced — bridging by netplan, the prober by a cross-compiled C binary (see `probe.yml`, sibling `prober/` repo).

### Systemd services

- `batman.service` — oneshot, `ExecStart=/usr/local/bin/config_batman.sh` (deployed from `config_batman2_electric_boogaloo.sh`), `MESH_SSID`/`MESH_CHANNEL` templated into its `Environment=` lines. Installed, enabled and started automatically by `tasks/00_configure_network_common.yml` — no manual step.
- `network_prober.service` — runs the C prober binary continuously (`Restart=always`), deployed by `probe.yml`.
- `fieldlog-resource.service` — installed enabled but stopped; `make start-logging`/`stop-logging` start/stop it on demand.
- `nat-routing.service` / `dnsmasq` — manager only, NAT and DHCP/DNS for the mesh.

### Network topology

```
Laptop ── eth0 ── [Manager Pi] ── batman-adv mesh (bat0) ── Worker Pis
        (wired setup LAN,          192.168.42.0/24 — manager fixed at
         discovery/SSH only)       .1, workers DHCP-leased from the
                                    manager's dnsmasq
```

Once provisioned, the manager and workers reach each other entirely over the mesh; the wired LAN (`WIRED_SCAN_SUBNET`, default `192.168.67.0/24`) is only needed for `discover.py`'s initial ARP scan, or as a fallback per-host (see Inventory above).

### Kubernetes / registry

`registry/zot.yml` deploys [Zot](https://zotregistry.dev) (an OCI-native registry with a web UI + CVE scanning, chosen over Harbor because Harbor's official images are amd64-only and don't run on the Pi cluster) as a K8s Deployment + NodePort service on port `30500`, pinned to the manager node, backed by a 5 Gi PVC using `local-path` storage class. Canonical address is `manager0.gotham:30500` — every image push/reference must use that exact string, since containerd's per-node TLS trust config keys off it unnormalized. TLS is a self-signed cert (`zot-tls` k8s secret, manually created); trusting its CA in every node's containerd is automated by `tasks/configure_registry_trust.yml` (part of `provision_all.yml`, reads the CA from `registry_ca_cert_path` in `group_vars/all.yml`, a controller-local file never committed to the repo). See `registry/README.md` for full setup.

## Known manual steps (not automated)

- Zot registry TLS: generate the cert and create the `zot-tls` k8s secret — see `registry/README.md`. (Trusting the CA on every node's containerd *is* automated.)
