# Cluster app spec

This is the normative spec for any app or service that runs on the Gotham
Raspberry Pi Kubernetes cluster.
It describes how existing apps (bapi, gps-client, maviz, object-detection,
radio-wrapper, sensehat-collector, sensehat-frontend) are actually built and
deployed, and states the conventions a new app must follow to interoperate
with them.
The `cluster-app-scaffold` skill in `ai-skills/` automates this spec; this
file is the source of truth it reads from.

## 1. Concept: how an app fits into the cluster

Each app is its own top-level repo directory, a sibling of `infra/`
(`~/repos/ffi/<app>/`), not nested inside `infra/`.
`infra/` owns the cluster itself (mesh, k3s, registry, capability detection,
the custom scheduler's config) and cluster-wide shared services (mosquitto,
Zot registry, dashboard).
An app repo owns its own `Dockerfile`, Kubernetes manifest(s), and
`Makefile`.
`infra`'s `make deploy` (`shellscripts/deployctl.sh`) discovers any
`kind: Deployment`/`kind: DaemonSet` manifest in sibling repos automatically
and drives it through that repo's own Makefile, so a new app needs no
central registration.

Every app declares three things:

- **Where it runs.** A `nodeSelector` on a `capability/<x>` label if it needs
  specific hardware or a role (camera, GPS, GUI-facing), otherwise
  unconstrained. See [4](#4-reference-kubernetes-manifest-fields) and
  [6](#6-reference-capability-labels).
- **How it reaches other apps.** A `NetworkComRequirements` env var so the
  custom scheduler can place it close to what it talks to, plus MQTT for
  actual data exchange. See [7](#7-reference-mqtt-conventions).
- **How it ships.** An arm64 image pushed to the in-cluster Zot registry at
  a fixed hostname. See [3](#3-reference-dockerfile-patterns).

## 2. Procedure: create a new app

Prerequisites:

- `kubectl` configured against the cluster (`make kubeconfig` in `infra/`).
- Trusted the Zot registry's TLS CA on your machine (`make registry-trust`
  in `infra/`, one-time).
- `docker buildx` with an arm64-capable builder.

1. Create the app directory as a sibling of `infra/`, e.g. `~/repos/ffi/<app>/`.
2. Write the `Dockerfile` following one of the patterns in
   [3](#3-reference-dockerfile-patterns).
3. Write the Kubernetes manifest (`deployment.yaml` at the repo root for a
   single-service app, or `k8s/*.yaml` for multiple manifests) using the
   fixed field set in [4](#4-reference-kubernetes-manifest-fields).
4. If the app needs specific hardware and no existing capability label fits,
   add a detection entry to `infra/playbooks/capabilities.yml` first (see
   [6](#6-reference-capability-labels)), then run `make label` (in `infra/`).
5. Write the `Makefile` using the standard target vocabulary in
   [8](#8-reference-makefile-target-vocabulary), so `infra`'s `make deploy`
   picks the app up with no extra wiring.
6. Build and push:
   `docker buildx build --platform linux/arm64 --push -t manager0.gotham:30500/<app>:latest .`
7. Apply the manifest: `make apply` (in the app repo) or `make deploy` (in
   `infra/`, fzf-pick the app).
8. If the app is a GUI-facing frontend, add a tile to
   `infra/dashboard/homepage.yml`'s `services.yaml` block.

Verification: `kubectl get pods -l app=<app>` shows the pod `Running`, and
either `mosquitto_sub -h manager0.gotham -p 31883 -t '<topic>/#' -v` shows
messages, or the app's NodePort responds
(`curl http://manager0.gotham:<nodePort>`).

## 3. Reference: Dockerfile patterns

| Pattern | When | Base image | Notes |
| --- | --- | --- | --- |
| Alpine + `uv` | Pure-Python app, no hardware apt deps | `python:3.14-alpine` | `COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /bin/`, then `uv sync`. See `gps-client/dockerfile`. |
| Debian + apt + `uv` | Needs Raspberry Pi hardware bindings not on PyPI (picamera2, libcamera) | `debian:bookworm-slim` | Add the `archive.raspberrypi.com` apt repo, `apt-get install` the hardware package, then `uv pip install --system --break-system-packages` for the rest so it lands in the same Python apt already populated. See `object-detection/Dockerfile`. |
| Python slim + pip | Needs a specific PyPI wheel index (e.g. CPU-only PyTorch for aarch64) | `python:3.11-slim-bookworm` | `pip install -r requirements.txt --extra-index-url <wheel index>`. See `radio-wrapper/processor/Dockerfile`. |
| Node multi-stage + nginx | Browser frontend | `node:24-alpine` build stage, `nginx:alpine` runtime stage | Build args (`ARG`/`ENV`) for `VITE_*` compile-time config; copy `dist/` and a repo-local `nginx.conf` into the runtime stage. See `maviz/Dockerfile`. |

Always target `linux/arm64` (Raspberry Pi OS 64-bit) — every Pi in the
cluster is arm64, there is no amd64 fallback path.
Build with `docker buildx build --platform linux/arm64 --push`, not `docker
build`; there is no local `docker run` step in the loop, images go straight
to the registry.
Runtime configuration (broker address, topic names, thresholds) is injected
by the Kubernetes manifest's `env:` block, never baked into the image.
A local `.env` file is for `make dev`-style local runs only.

## 4. Reference: Kubernetes manifest fields

| Field | Value / convention | Why |
| --- | --- | --- |
| `kind` | `DaemonSet` for one-per-node hardware-tied services (GPS, Sense HAT, camera); `Deployment` (usually `replicas: 1`) for everything else | A DaemonSet auto-schedules on every matching node without a replica count to keep in sync. |
| `image` | `manager0.gotham:30500/<app>:latest` | Must byte-match this hostname — containerd's per-node TLS trust is keyed off it unnormalized (see `infra/registry/README.md`). |
| `imagePullPolicy` | `Always` | Tags are always `:latest`; without `Always` a `rollout restart` won't fetch the new image. |
| `schedulerName` | `custom-scheduler` | Opts the pod into placement scoring by latency/throughput/capability instead of the default scheduler. Omit only for cluster-bootstrap services that must schedule before the custom scheduler is up (mosquitto, Zot, venividivici). |
| `nodeSelector: capability/<x>: "true"` | Only for hardware- or role-gated apps | See [6](#6-reference-capability-labels). Value must be the literal string `"true"`, not a boolean — it unmarshals into a Go struct on the scheduler side. |
| `tolerations` (2 entries) | `node.kubernetes.io/not-ready` and `node.kubernetes.io/unreachable`, `NoExecute`, `tolerationSeconds: 30` | Copy verbatim onto every pod spec. Pis routinely drop off the mesh for a few seconds; without this the default 5-minute-then-evict policy briefly evicts and reschedules healthy pods. |
| `env: NetworkComRequirements` | JSON array: `[{"Target": "<role>", "Latency": <ms>, "Throughput": <Mbps>}]` | Consumed by the custom scheduler (`scheduler/k8_scheduler/common/utils.go: PodToVertex`), not by the app itself. `Target` is a free-text role name meaningful across the cluster graph — reuse `"mosquitto"` for anything that mainly talks to the broker, or another app's own name (e.g. `"bapi"`) for a direct dependency. |
| `env: NODE_NAME` | `valueFrom.fieldRef.fieldPath: spec.nodeName` | Standard for anything that tags its own MQTT topic or log lines with which Pi it ran on. |
| `resources.requests`/`limits` | Always set, sized for a Pi (tens–hundreds of `m` CPU, tens–hundreds of `Mi` memory) | These are Raspberry Pis, not workstations; an unbounded pod can starve the node. |
| `securityContext.privileged: true` + `hostPath` mounts | Only for apps needing direct hardware access (`/dev`, `/sys/kernel/debug`, `/run/udev`) | Camera, Sense HAT, GPS. Mount only the specific hostPath the app touches, not the whole filesystem. |
| `Service.type` | `NodePort` with an explicit `nodePort:` | Never let Kubernetes auto-assign — operators need a stable, memorable port. Check [5](#5-reference-nodeport-registry) before picking a new one. |

## 5. Reference: NodePort registry

| Port | Service | Repo |
| --- | --- | --- |
| 30080 | sensehat-frontend | `sensehat-frontend/frontend.yml` |
| 30100 | dashboard (homepage) | `infra/dashboard/homepage.yml` |
| 30500 | Zot registry | `infra/registry/zot.yml` |
| 30800 | bapi | `bapi/deployment.yaml` |
| 30808 | object-detection viewer | `object-detection/k8s/service.yaml` |
| 30880 | maviz | `maviz/deployment.yaml` |
| 30901 | mosquitto (websocket) | `infra/mosquitto/mosquitto.yml` |
| 31883 | mosquitto (MQTT) | `infra/mosquitto/mosquitto.yml` |

Pick an unused port outside this table for a new `NodePort` service.
Kubernetes' default NodePort range is 30000–32767.

## 6. Reference: capability labels

Two different mechanisms both produce `capability/<x>: "true"` node labels —
do not confuse them.

**Auto-detected** (via `infra/playbooks/capabilities.yml`, applied by
`make label` or `make provision`): the detection command follows a 3-way
exit-code contract (`0` present, `1` absent, anything else is a surfaced
error, node left unlabeled that run).
Labels are add-only — a capability that stops being detected on a later run
is never removed.

| Label | Meaning | Detected by |
| --- | --- | --- |
| `capability/gps` | GPS receiver at the normalized `/dev/gps0` | Live NMEA/UBX sentence via a throwaway `gpsd` probe |
| `capability/ai-camera` | Raspberry Pi AI Camera (IMX500) | `rpicam-hello --list-cameras` (fallback `libcamera-hello`) mentions `imx500` |
| `capability/sensehat` | Sense HAT (ATTINY88 @ I2C 0x46) | `i2cdetect -y 1 0x46 0x46` |
| `capability/rpi5` | Hardware is a Pi 5 | `/proc/device-tree/model` |
| `capability/rpi3` | Hardware is a Pi 3 | `/proc/device-tree/model` |

**Manually applied** (`kubectl label node <name> capability/<x>=true`, no
entry in `capabilities.yml`): used for role-based placement that isn't a
physical hardware fact.

| Label | Meaning |
| --- | --- |
| `capability/gui` | This node should host browser-facing frontends (maviz, bapi, sensehat-frontend, dashboard). |

Adding a new hardware capability: add an entry under `capabilities:` in
`infra/playbooks/capabilities.yml` with `description`, `command` (honoring
the exit-code contract), `become`, `timeout`, `hosts`, then run `make label`.
Do not invent a new `nodeSelector` value that has no corresponding entry
here or manual-labeling convention — the pod will never schedule.

## 7. Reference: MQTT conventions

Broker addresses:

- In-cluster (pod-to-pod): `mosquitto.default.svc.cluster.local:1883`.
- From the laptop or off-cluster: NodePort `<any-node-ip>:31883`
  (`manager0.gotham:31883` works), websocket variant on `:30901`.

Topic naming: `<kind>/<domain>/<node-name>` for per-node published data
(`data/gps/worker3`, `data/sensehat/worker7`), `<kind>/<domain>` for
cluster-wide events with no single owning node (`network/linkdata`,
`events/radio-classification`).
`<kind>` is one of `data` (raw sensor/telemetry), `events` (derived
results), or `jobs` (work dispatch, e.g. `object-detection`'s
camera-to-worker crop batches).

Client pattern (Python, `paho-mqtt`):

```python
import paho.mqtt.client as mqtt
from paho.mqtt.enums import CallbackAPIVersion

client = mqtt.Client(callback_api_version=CallbackAPIVersion.VERSION2)
client.on_connect = on_connect
client.reconnect_delay_set(min_delay=1, max_delay=30)
client.connect_async(MQTT_BROKER, MQTT_PORT)
client.loop_start()
```

Always pass `callback_api_version=CallbackAPIVersion.VERSION2` — every app
in this cluster uses the v2 callback signature
(`on_connect(client, userdata, flags, reason_code, properties)`), mixing
v1 and v2 callbacks across apps subscribing to the same broker is a source
of confusing `TypeError`s.
Prefer `connect_async` + `reconnect_delay_set` + `loop_start()` over a
bare `connect()` — it survives the broker restarting without the app
crashing.
Read the broker address and topic from environment variables
(`MQTT_HOST`/`MQTT_BROKER`, `MQTT_PORT`, `MQTT_TOPIC`) with sane defaults,
never hardcode them — the name pair isn't perfectly consistent across
existing apps (`MQTT_HOST` vs `MQTT_BROKER`), match whichever pair the
pipeline you're extending already uses.
Use `qos=1` for telemetry that must not be silently dropped (a GPS fix);
default `qos=0` is fine for a high-frequency, individually low-value
stream.

## 8. Reference: Makefile target vocabulary

`infra`'s `make deploy` (`shellscripts/deployctl.sh`) recognizes exactly
these five actions and runs `make <action>` in the app's own repo if that
target exists, falling back to a direct `kubectl` equivalent otherwise
(no fallback exists for `build`, since there is no way to infer an image
name from nothing):

| Target | Does |
| --- | --- |
| `build` | `docker buildx build --platform linux/arm64 --push -t manager0.gotham:30500/<app>:latest .` |
| `apply` | `kubectl apply -f <manifest>` |
| `logs` | `kubectl logs -f <kind>/<name>` |
| `rollout` | `kubectl rollout restart <kind>/<name>` |
| `delete` | `kubectl delete -f <manifest>` |

Also include a self-documenting `help` target (every existing Makefile uses
the same `awk`-over-`## comment` pattern — copy one, e.g.
`gps-client/Makefile`).
`exec` (shell into the running pod) is common but optional.
Apps with more than one manifest (camera + worker, receiver + processor)
split `build`/`apply`/`rollout`/`logs` per component
(`build-camera`/`build-worker`, ...) and add a combined top-level `apply`/
`restart` target — see `object-detection/Makefile`.

## 9. Troubleshooting

### A rebuilt image doesn't take effect after `make rollout`

**Cause:** `imagePullPolicy` is missing or not `Always`, so kubelet reuses
the cached `:latest` layer instead of re-pulling.

**Fix:** Set `imagePullPolicy: Always` on the container spec, then
`kubectl rollout restart`.

### Pod stays `Pending` forever

**Cause:** its `nodeSelector` requests a `capability/<x>` label that no
node actually has — either the hardware check never ran (`make label`
not applied) or the label name was invented rather than taken from
[6](#6-reference-capability-labels).

**Fix:** `kubectl get nodes --show-labels` and compare against the
manifest's `nodeSelector`. Run `make label` in `infra/` if the capability
should be auto-detected but isn't showing up.

### `docker push` fails with a TLS error

**Cause:** this machine hasn't trusted the Zot registry's self-signed CA
yet, or the image reference doesn't byte-match
`manager0.gotham:30500/<app>` (containerd's trust config is keyed off the
literal string).

**Fix:** `make registry-trust` in `infra/`. Double-check the tag matches
`manager0.gotham:30500/<app>:latest` exactly.

### `mosquitto_sub` from the laptop hangs with no messages

**Cause:** using the in-cluster DNS name
(`mosquitto.default.svc.cluster.local`) from off-cluster, where it doesn't
resolve, instead of the NodePort.

**Fix:** connect to `manager0.gotham:31883` (or the mesh manager IP) from
outside the cluster; use the ClusterIP DNS name only from inside a pod.

## Related

- `infra/registry/README.md` — Zot registry setup and TLS trust, in full.
- `infra/playbooks/capabilities.yml` — capability detection source, with
  revision history explaining why each check looks the way it does.
- `scheduler/` — the custom scheduler that reads `NetworkComRequirements`
  and capability labels.
- `infra/shellscripts/deployctl.sh` — the cross-repo deploy picker this
  spec's Makefile vocabulary is designed to work with.
