# infra

Ansible and shell automation for a Raspberry Pi MANET cluster with Kubernetes (K3s).

## 01 - System description

This repo provisions a self-contained Raspberry Pi cluster for field-testing edge computing in mobile, low-connectivity networks.
Ansible sets up each node and connects them with B.A.T.M.A.N. mesh routing (`batman-adv`) over Wi-Fi ad-hoc.
One node has the manager role: it runs the K3s control plane and hands out IP addresses and DNS names to the rest of the mesh network over `bat0`.

### Components

| Component | Runs on | Description |
|---|---|---|
| Mesh network (`batman-adv`) | All nodes | Routes traffic between nodes without fixed infrastructure. |
| K3s | All nodes | Kubernetes distribution for edge devices. Manager runs the control plane. |
| dnsmasq | Manager | Hands out DHCP addresses and DNS names (`*.gotham`) on the mesh network. |
| Zot | Manager (pod) | OCI registry for container images. See `registry/README.md`. |
| Mosquitto | Cluster (pod) | MQTT broker. Collects sensor and link data from all nodes. |
| Network prober | All nodes | Measures link latency and throughput. Publishes the result to MQTT. |
| Field logging service | All nodes | Logs CPU, memory and disk usage during an experiment. |
| Custom scheduler (`k8-scheduler`) | Manager | Places pods based on mesh topology instead of default Kubernetes logic. |
| venividivici | Manager (pod) | Watches the wired network and provisions new Raspberry Pi devices automatically. |
| Dashboard | Cluster (pod) | Overview pages for cluster status and apps. Reachable at `http://dashboard.gotham`. |

Applications that run on the cluster (object detection, radio classification, GPS client) live in separate repos alongside this one.
See section 04 for how they are deployed from here.

## 02 - Installation and requirements

### Prerequisites

Requirements for the control machine (the laptop you run Ansible from):

* `ansible` and `python3`
* `kubectl`
* Passwordless `sudo nmap`. `inventories/discover.py` uses it to scan the network for Pi devices.
* `fzf`. Required by `make deploy` and `make watch`.
* `sshpass`. Required by `make watch`. The Pi devices use a password, not an SSH key, by default.
* Go with `GOOS=linux GOARCH=arm64` cross-compilation. Required only by `make deploy-scheduler`.

Requirements for each Raspberry Pi:

* Unmodified Raspberry Pi OS image.
* Default SSH username and password (`pi` / `raspberry`), or custom values set in `.env`.
* Connection to the same wired network as the control machine, for initial discovery.

### Installation steps

1. Clone this repo.
2. Run `cp .env.example .env` in the repo root.
3. Edit `.env` if the default values do not match your network. See section 03.
4. Connect all Raspberry Pi devices to the wired setup network.
5. Run `make discover` to confirm the system finds all the devices.
6. Run `make provision` to configure the mesh network, K3s and registry trust.
7. Run `make kubeconfig` to get cluster access on the control machine.
8. Run `kubectl get nodes` to confirm every node has status `Ready`.
9. Run `kubectl apply -f mosquitto/mosquitto.yml` to deploy the MQTT broker.
10. Follow `registry/README.md` to set up the Zot registry (requires a TLS certificate).

Steps 9 and 10 are required for a working cluster: the network prober publishes link data to Mosquitto, and app deployment (section 04) needs a registry to push images to.

Provisioning is idempotent.
Run `make provision` again to verify or repair a node without risk.

## 03 - Configuration

All configuration happens in `.env`, copied from `.env.example`.
Ansible reads the same values through `playbooks/group_vars/all.yml`, with the same default values as fallback.

There is no static inventory file to edit.
`inventories/discover.py` finds Pi devices on the network itself, and stores MAC-to-name mappings in `inventories/discovered_hosts.json`.
This file is tracked in git and travels with the repo between machines.

### Mesh network

| Variable | Default value | Description |
|---|---|---|
| `MESH_MANAGER_IP` | `192.168.42.1` | The manager's fixed IP on `bat0`. |
| `MESH_DHCP_START` / `MESH_DHCP_END` | `192.168.42.2` - `192.168.42.254` | The DHCP range the manager hands out to workers on `bat0`. |
| `MESH_DHCP_LEASE_HOURS` | `12` | The length of each DHCP lease, in hours. |
| `MESH_SSID` | `meshnet` | The Wi-Fi name the ad-hoc network uses. All nodes must use the same value. |
| `MESH_CHANNEL` | `1` | The Wi-Fi channel the ad-hoc network uses. |
| `MESH_DOMAIN` | `gotham` | The DNS suffix the manager's dnsmasq answers on, e.g. `manager0.gotham`. |

### Wired setup network

| Variable | Default value | Description |
|---|---|---|
| `WIRED_SCAN_SUBNET` | `192.168.67.0/24` | The network `discover.py` scans to find Pi devices. |
| `MANAGER_WIRED_IP` | (empty) | The manager's fixed `eth0` IP. Only needed without a router in the field. See `field-phase-one`/`field-phase-two` in section 04. |
| `MANAGER_HOST` | `manager0.local` | The manager's mDNS name, used by `watchctl.sh`. |

### Pi access

| Variable | Default value | Description |
|---|---|---|
| `PI_SSH_USER` | `pi` | Username for SSH to each Pi. |
| `PI_SSH_PASSWORD` | `raspberry` | Password for SSH to each Pi. This is Raspberry Pi OS's publicly known default value, not a secret. |

### K3s and registry

| Variable | Default value | Description |
|---|---|---|
| `K3S_API_PORT` | `6443` | The port K3s's API server listens on. |
| `REGISTRY_HOST` / `REGISTRY_PORT` | `manager0.gotham` / `30500` | The address of the Zot registry. Every image reference in the cluster must match this value exactly. |

The TLS certificate for the registry is generated manually, outside the repo.
See `registry/README.md`.

### Field logging

| Variable | Default value | Description |
|---|---|---|
| `FIELDLOG_INTERVAL` | `5` | Seconds between each CPU/memory/disk measurement. |
| `FIELDLOG_MAX_SIZE_KB` | `10240` | Maximum file size before the log file is rotated. |
| `FIELDLOG_ALL_ROUTES` | `false` | `true` also logs routes not in use. For troubleshooting only. |
| `SCHEDULER_LOG_WINDOW` | `2 hours ago` | How far back `make collect-logs` fetches scheduler logs. |
| `APP_LOG_WINDOW` | `2h` | How far back `make collect-logs` fetches application logs. |

### Network prober and MQTT

| Variable | Default value | Description |
|---|---|---|
| `PROBE_MQTT_HOST` / `PROBE_MQTT_PORT` | `127.0.0.1` / `31883` | The MQTT broker each node publishes link data to. |
| `MQTT_TOPIC_LINKDATA` | `network/linkdata` | The MQTT topic link data is published on. |

### venividivici

**Note:** venividivici is at a very early development stage (WIP). Use with caution.

| Variable | Default value | Description |
|---|---|---|
| `VENIVIDIVICI_POLL_INTERVAL` | `30` | Seconds between each scan for new Pi devices. |
| `VENIVIDIVICI_SSH_PROBE_TIMEOUT` | `5` | Seconds before an SSH attempt to a new node gives up. |
| `VENIVIDIVICI_MQTT_BROKER` / `VENIVIDIVICI_MQTT_PORT` | `mosquitto.default.svc.cluster.local` / `1883` | The MQTT broker in the cluster, used internally by venividivici. |

## 04 - Usage

### Quick start

```bash
cp .env.example .env
make discover
make provision
make kubeconfig
```

Run `make help` for the full list of commands, with descriptions.
Most commands accept `LIMIT=<node>` to restrict the run to one node.
`<node>` is the hostname from `make discover` (`manager0`, `worker0`, `worker1`, ...).
Example: `make provision LIMIT=worker0`.

### Core commands

**Discovery**

* `make discover`: Lists Pi devices found on the network. No SSH connection.
* `make discover-model`: Same as above, but connects to each device and shows the Pi model.
* `make ping`: Ansible ping against all discovered nodes.
* `make status`: Shows apt/dpkg activity on all nodes. Used to check whether provisioning is stuck.
* `make identify LIMIT=<node>`: Blinks a Pi's activity LED for 30 seconds.

**Provisioning**

* `make provision`: Runs full provisioning. Use `TAGS=<name>` or `SKIP=<name>` to limit the scope.
* `make reset`: Removes K3s, mesh configuration and all provisioning traces from all nodes. Asks for confirmation.
* `make reboot`: Restarts all nodes. Asks for confirmation.

**Automated provisioning (venividivici)**

* `make venividivici-build`: Builds and pushes venividivici's image to Zot.
* `make venividivici-apply`: Deploys the venividivici pod on the manager.
* `make venividivici-logs`: Follows venividivici's log live.
* `make venividivici-delete`: Removes the venividivici deployment.
* `make venividivici-rollout`: Restarts the venividivici pod.

**Cluster administration**

* `make kubeconfig`: Fetches kubeconfig from the manager to `~/.kube/config`.
* `make kubeconfig-copy HOST=<node>`: Copies kubeconfig to another Pi.
* `make label`: Re-runs capability detection and updates k8s labels. Does not remove old labels.

**Deployment**

* `make deploy ACTION=<apply|logs|delete|build|rollout>`: Picks a Kubernetes deployment from this repo or a sibling repo, and runs the selected action. Without `ACTION`, the action is chosen interactively.
* `make deploy-scheduler`: Builds and deploys the custom scheduler. Requires `SCHEDULER_DIR` set to the scheduler repo, default `../scheduler`.

**Registry**

* `make registry-trust`: Sets up this machine to push to the Zot registry. See `registry/README.md`.

**Observation**

* `make watch`: Picks and streams a live cluster view (scheduler log, pods, nodes, services).

**Field logging**

* `make start-logging`: Synchronizes the clock on all nodes, then starts field logging. Use `SESSION=<id>` to resume a session.
* `make stop-logging`: Stops field logging on all nodes.
* `make collect-logs`: Fetches logs from all nodes to `collected-logs/synced/`.

**Maintenance**

* `make known-hosts-reset`: Removes old SSH keys for all nodes. Run after a Pi has been reflashed, or when SSH warns that a host key does not match (`WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED`).

**Field experiment without a router**

* `make field-phase-one`: Sets the manager's fixed `eth0` IP. Run before moving the cable from router to laptop.
* `make field-phase-two`: Confirms the manager after the cable swap.

## 05 - Troubleshooting

* Symptom: `make provision` or `make reset` fails partway through.
  * Fix: Run the command again. Common causes are a locked apt file, a slow K3s install, or a node that has not finished booting. A rerun usually fixes this.
* Symptom: A worker is not visible in mesh traffic (missing from `batctl n`, or does not respond to ping over `bat0`).
  * Fix: Run `make reboot LIMIT=<node>`. This usually resolves the issue.
* Symptom: A worker responds normally in mesh traffic, but is missing or `NotReady` in `kubectl get nodes`.
  * Fix: Connect to the node over SSH and run `systemctl restart k3s-agent`. The service may have started on `eth0` before `bat0` was ready.
* Symptom: A removed device (e.g. GPS) still has its capability label on the node.
  * Fix: Remove the label manually with `kubectl label node <node> capability/<name>-`. Capability detection never removes old labels automatically.
* Symptom: Timestamps in field logs do not match the actual time.
  * Fix: Use `make start-logging`, not a manual `systemctl start`. It synchronizes the clock against the laptop first. The manager does not necessarily have internet access in the field.
* Symptom: `docker push` to the registry fails with a certificate error.
  * Fix: Run `make registry-trust` on the machine doing the push.
* Symptom: A pushed image cannot be pulled on the cluster.
  * Fix: Check that the image reference matches `REGISTRY_HOST:REGISTRY_PORT` exactly, as set in your `.env` (default `manager0.gotham:30500`, see section 03). Any deviation from this string fails.
* Symptom: `make deploy ACTION=build` does nothing for an image.
  * Fix: Run the build command directly in the relevant repo. `deployctl.sh` has no generic build function.
* Symptom: The cluster loses all access when the manager goes offline.
  * Fix: No automatic fix exists today. The cluster has neither manager failover nor election of a new manager. Restart the manager, or provision a new manager manually.
