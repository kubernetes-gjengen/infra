---
name: cluster-app-scaffold
description: >
  Scaffold a new app or service that runs on the Gotham Raspberry Pi
  Kubernetes cluster: Dockerfile, k8s manifest, Makefile, MQTT wiring,
  capability labels, registry push. Use when the user asks to create a new
  app or service for the cluster, add a new sensor/collector/worker/
  frontend, containerize something for the Pis, or asks "hvordan lager jeg
  en ny app/tjeneste for clusteret", "sett opp en ny tjeneste", "legg til
  en ny sensor-app", "scaffold a new service", "dockerize this for the
  cluster". The normative spec with full reference tables is
  infra/CLUSTER-APP-SPEC.md — read it before writing manifests, don't rely
  on this file's summary alone.
---

# Cluster app scaffold

Every app in this project (`bapi`, `gps-client`, `maviz`, `object-detection`,
`radio-wrapper`, `sensehat-collector`, `sensehat-frontend`, ...) is a
top-level repo directory, a sibling of `infra/`, each owning its own
`Dockerfile`, Kubernetes manifest, and `Makefile`.
`infra/` owns only the cluster itself and shared services (mosquitto, the
Zot registry, the dashboard); it never hosts app code.
The full conventions — Dockerfile patterns, manifest field table, port
registry, capability labels, MQTT topic scheme, Makefile target vocabulary,
troubleshooting — live in `infra/CLUSTER-APP-SPEC.md`.
This skill is the workflow; that file is the reference.

## Workflow

1. Read `infra/CLUSTER-APP-SPEC.md` section 2 (procedure) before writing
   anything — do not improvise a manifest shape from a different app you
   remember, conventions drift between apps in small but load-bearing ways
   (env var naming, tolerations, `NetworkComRequirements`).
2. Decide the app's shape: a hardware-tied one-per-node service
   (GPS, Sense HAT, camera) is a `DaemonSet`; everything else is a
   `Deployment`. This decides whether it needs a `capability/<x>`
   `nodeSelector` at all.
3. Create the app directory as a sibling of `infra/`
   (`~/repos/ffi/<app>/`), never nested inside `infra/`.
4. Write the `Dockerfile` using the matching pattern from spec section 3
   (alpine+uv, debian+apt+uv, python-slim+pip, or node-multistage+nginx).
   Always `--platform linux/arm64` — there is no amd64 path on this
   cluster.
5. Write the manifest using the fixed field set from spec section 4:
   `schedulerName: custom-scheduler`, the two-entry tolerations block,
   `NetworkComRequirements` (JSON, declares what this pod talks to and how
   much it cares about latency/throughput to it), `NODE_NAME` via
   `fieldRef` if the app tags its own output by node, sized
   `resources.requests`/`limits`.
6. If the app is hardware-gated and no capability label in spec section 6
   fits, add a detection entry to `infra/playbooks/capabilities.yml`
   first (exit-code contract: `0` present, `1` absent, else error), then
   run `make label` in `infra/`. Never invent a `nodeSelector` value with
   no corresponding detection or manual-labeling convention — the pod will
   sit `Pending` forever.
7. If the app needs a `NodePort`, pick one outside the table in spec
   section 5 and add the new entry to that table.
8. Write the `Makefile` with the standard target vocabulary from spec
   section 8 (`build`, `apply`, `logs`, `rollout`, `delete`, `help`) so
   `infra`'s `make deploy` (`shellscripts/deployctl.sh`) picks the app up
   automatically — no central registration needed.
9. Build, push, apply:
   `docker buildx build --platform linux/arm64 --push -t manager0.gotham:30500/<app>:latest .`,
   then `make apply`.
10. Verify end to end: `kubectl get pods -l app=<app>` shows `Running`, and
    either `mosquitto_sub -h manager0.gotham -p 31883 -t '<topic>/#' -v`
    shows real messages or the app's `NodePort` responds to `curl`.
11. If it's a GUI-facing frontend, add a tile to
    `infra/dashboard/homepage.yml`'s `services.yaml`.

## Checklist before calling it done

- [ ] Dockerfile targets `linux/arm64` only
- [ ] Image tag is exactly `manager0.gotham:30500/<app>:latest`
- [ ] `imagePullPolicy: Always` set (tags are always `:latest`)
- [ ] Manifest has `schedulerName: custom-scheduler`, the tolerations
      block, and a `NetworkComRequirements` env var
- [ ] Any `capability/<x>` nodeSelector traces to an entry in
      `infra/playbooks/capabilities.yml` or the manual-labeling table in
      the spec — not invented
- [ ] `resources.requests`/`limits` set, sized for a Pi
- [ ] Any new `NodePort` is unused and added to the spec's port table
- [ ] Makefile implements at least `build`, `apply`, `logs`, `rollout`,
      `delete`
- [ ] Verified end to end: pod `Running`, and MQTT messages seen or HTTP
      endpoint responds — not just `kubectl apply` succeeding

## Limits

Don't invent new capability labels, MQTT topic roots, or reuse a
`NodePort` without checking `infra/CLUSTER-APP-SPEC.md`'s tables first —
collisions break other apps silently, they don't error loudly.
Don't skip the tolerations block to save lines — Pis drop off the mesh
for a few seconds routinely, and pods without it get evicted for that.
Host-level provisioning (Ansible, mesh config, k3s itself) is out of scope
for this skill — that's `infra/playbooks/`, a different layer.
