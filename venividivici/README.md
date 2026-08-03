# venividivici

Automates what `make provision` used to require a laptop for: watches the
wired setup LAN (`192.168.3.0/24`) for Pis that have never been seen before,
and runs `provision_all.yml` against them the moment they're SSH-reachable.
Runs as a `Deployment` pinned to manager0 (needs `hostNetwork` to see the
wired LAN directly, same reason `discover.py` requires passwordless
`sudo nmap`).

New Pis are queued (`pending` MAC->IP map in `controller.py`) and
provisioned in a single batched `provision_all.yml` run whenever at least
one becomes reachable - the playbook is unrestricted/inventory-driven, so
one run already covers every new host together, plus re-verifies existing
nodes (this is also what keeps every node's `/etc/hosts`/registry-trust
config in sync when a new node joins, matching what a manual `make provision`
already does).

Each newly-seen MAC also publishes one MQTT event to `event/node-discovered`
on the existing mosquitto broker (`mosquitto.default.svc.cluster.local:1883`)
- `{ip, mac, timestamp}` - for a future frontend to consume.

## One-time setup

### 1. Registry CA secret

Same CA cert used by `make registry-trust` (see `registry/README.md`) needs
to be reachable from inside the pod, since it now runs `ansible-playbook`
itself instead of a laptop:

```bash
kubectl create secret generic registry-ca \
  --from-file=registry-ca.crt=$HOME/certs/registry-ca.crt
```

### 2. Build and deploy

```bash
make venividivici-build   # builds + pushes the arm64 image to the Zot registry
make venividivici-apply   # applies venividivici.yaml
make venividivici-logs    # follow the controller loop
```

## Notes

- Deploying via `make deploy` (`deployctl.sh`) also works for `apply`/
  `delete`/`rollout` once picked from the fzf list - it just won't create
  the registry-ca secret for you (step 1 is one-time, like the zot TLS
  secret already is). `venividivici-apply` itself handles the hostPath
  state file idempotently every run, no separate one-time step needed.
- `build` has no `deployctl` fallback (same as every other custom-built
  image in this repo) - use `make venividivici-build` directly.
