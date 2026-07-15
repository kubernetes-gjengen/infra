# infra

Ansible + shell automation for a Raspberry Pi MANET cluster: B.A.T.M.A.N. mesh routing (`batman-adv`) between the Pis, k3s on top, a manager node bridging the mesh to the operator's laptop via ethernet.

## Requirements

- `ansible`, `python3` (dynamic inventory), `kubectl`
- passwordless `sudo nmap` on this machine (used by `inventories/discover.py` to ARP-scan `192.168.3.0/24`)
- `fzf` (for `make deploy` / `make watch`)
- `sshpass` (for `make watch`; Pis auth by password, user/pass override via `SSH_USER`/`SSH_PASS` env vars)
- Go + `GOOS=linux GOARCH=arm64` cross-compile support (only for `make deploy-scheduler`)

## Config

- `playbooks/group_vars/all.yml` - `manager_mesh_ip`, `registry_host`, `registry_ca_cert_path` (controller-local path to the Zot CA cert, generated per `registry/README.md`, never committed)
- No inventory file to edit - `inventories/discover.py` is the default inventory (set in `playbooks/ansible.cfg`) and finds Pis on the LAN itself. `inventories/discovered_hosts.json` (gitignored) persists MAC→hostname/manager assignments across runs.
- Manual, one-time, per-Pi steps not covered by any target: copy `batman.service` to `/etc/systemd/system/` and `sudo systemctl enable batman`; create `/home/pi/ip_addr` containing that Pi's desired mesh IP (the service reads it on boot and fails without it).

## Make targets

Run `make help` for the full, current list with descriptions. All targets except `discover`/`ping`/`status` accept `LIMIT=<host>` to target one node.

- `discover`, `ping`, `status`, `identify` - inventory / health checks
- `provision` - run `provision_all.yml` (`TAGS=`/`SKIP=` to scope, e.g. `prober`)
- `kubeconfig` - fetch kubeconfig from the manager to `~/.kube/config`
- `label` - re-detect hardware capabilities and relabel k8s nodes
- `reset`, `reboot` - destructive; both prompt for confirmation
- `deploy` - fzf-pick a k8s Deployment (across this repo and sibling repos, see below) and an action (`apply`/`logs`/`delete`/`build`/`rollout`)
- `deploy-scheduler` - build and deploy the custom scheduler binary; needs `SCHEDULER_DIR` (see below)
- `registry-trust` - trust the Zot registry's TLS CA on this machine
- `watch` - fzf-pick a live cluster view (scheduler logs, pods, nodes, services) and stream it

## Sibling repos

Several targets look outside `infra/` at sibling checkouts under the same parent directory (`~/repos/ffi/*` by convention):

- `make deploy` (`shellscripts/deployctl.sh`) scans `infra`'s siblings for any `*.yml`/`*.yaml` containing `kind: Deployment` (skipping Helm `templates/` dirs). Each matching repo's own `Makefile` supplies the `apply`/`logs`/`delete`/`build`/`rollout` target if it has one (e.g. `object-detection/Makefile`, `gps-client/Makefile`); otherwise a generic `kubectl` fallback is used (no fallback exists for `build` - there's no way to infer an image name from nothing).
- `make deploy-scheduler` needs a checkout of the scheduler repo, expected at `../scheduler` next to `infra/` - override with `SCHEDULER_DIR=/path/to/scheduler` if yours lives elsewhere.

Apps therefore deploy from their own repos' manifests/Makefiles; `infra` only provides the cluster and the pickers that reach into those repos.
