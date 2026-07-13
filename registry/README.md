# Zot registry

Replaces the old plain `registry:2` deployment. [Zot](https://zotregistry.dev)
is an OCI-native registry with a built-in web UI and CVE scanning, and -
unlike Harbor - ships official multi-arch images (including `linux/arm64`),
so it actually runs on the Pi cluster. Pinned to the manager node
(`node-role.kubernetes.io/control-plane`) via `zot.yml`.

Security was explicitly out of scope for this setup: everything is
anonymous/unauthenticated (anyone who can reach the NodePort can push and
pull), and the TLS cert below is self-signed with a 10-year lifetime purely
so Docker/containerd stop refusing to talk to it - not for any real trust
guarantee.

**Canonical address: `manager0.gotham:30500`.** This is the exact string
every image reference (`docker push`, and any `image:` field in a k8s
manifest anywhere in the fleet) must use. containerd's registry-trust config
(`/etc/rancher/k3s/registries.yaml`, deployed by the playbook - see step 2)
keys off this string byte-for-byte, unnormalized: push or reference an image
under any other host/IP and k8s pulls will fail with a cert error even
though the push itself succeeded. `manager0.gotham` is dnsmasq's DNS name
for the manager's fixed mesh IP (`192.168.42.1`) - already relied on
elsewhere in this playbook for the same reason (`K3S_URL` in
`tasks/install_k3s_worker.yml`), and it survives the manager's wired IP
changing later, unlike a bare IP address.

## One-time setup

### 1. Generate a self-signed CA + server cert

Run this on the machine you run ansible from, in a scratch directory
**outside the repo** (the key material shouldn't be committed - see the
`registry/*.key`/`*.crt`/etc. entries in `.gitignore`).

Edit the `IP.*`/`DNS.*` lines in the config below to match every
address/hostname you'll actually use to reach the registry.

```bash
openssl genrsa -out registry-ca.key 4096
openssl req -x509 -new -nodes -key registry-ca.key -sha256 -days 3650 \
  -subj "/CN=manet-registry-ca" -out registry-ca.crt

cat > registry-san.cnf <<'EOF'
[req]
distinguished_name = req_distinguished_name
req_extensions = v3_req
prompt = no
[req_distinguished_name]
CN = 192.168.3.18
[v3_req]
subjectAltName = @alt_names
[alt_names]
IP.1 = 192.168.3.18
IP.2 = 192.168.42.1
DNS.1 = manager0
DNS.2 = manager0.local
DNS.3 = manager0.gotham
EOF

openssl genrsa -out registry.key 4096
openssl req -new -key registry.key -out registry.csr -config registry-san.cnf
openssl x509 -req -in registry.csr -CA registry-ca.crt -CAkey registry-ca.key \
  -CAcreateserial -out registry.crt -days 3650 -sha256 \
  -extfile registry-san.cnf -extensions v3_req
```

You now have `registry-ca.crt` (the CA cert distributed to every client
below) and `registry.crt`/`registry.key` (the server cert/key, for the k8s
secret only).

Put `registry-ca.crt` at `~/certs/registry-ca.crt` on the controller (keep
`registry-ca.key` next to it so you can reissue later) - that's what
`registry_ca_cert_path` in `playbooks/group_vars/all.yml` points at by
default, and step 2 below reads it from there.

### 2. Trust the CA on every node (k3s/containerd) - automated

```bash
cd playbooks && ansible-playbook provision_all.yml
```

This runs `tasks/configure_registry_trust.yml` against `manager:worker`:
copies `registry-ca.crt` to `/etc/rancher/k3s/registry-ca.crt` on every
node, writes `/etc/rancher/k3s/registries.yaml` pointing containerd at it
for `manager0.gotham:30500`, and restarts `k3s`/`k3s-agent` only when
either file actually changed (so a routine re-provision is a no-op here).
Runs automatically on every future `make provision` too, including for
newly-joined Pis - no more per-node manual copying.

If you'd rather not run the whole playbook right now, `--tags` doesn't
currently cover this step in isolation; it's part of the untagged main
flow (fast to target with `--limit` if you just need one node re-synced,
e.g. `ansible-playbook provision_all.yml --limit worker2`).

### 3. Create the namespace and TLS secret, then deploy

```bash
kubectl create namespace registry
kubectl create secret tls zot-tls -n registry \
  --cert=registry.crt --key=registry.key

kubectl apply -f registry/zot.yml
```

(`registry/zot.yml` also declares the `registry` namespace, so re-applying
it is safe/idempotent even though you created it by hand above.)

### 4. Configure a laptop to `docker push` - `make registry-trust`

Every machine that pushes needs two things: to resolve `manager0.gotham`
(required, since you must tag/push under that exact name - see the callout
above) and to trust the CA for it. `make registry-trust` (from the repo
root) does both in one shot:

```bash
make registry-trust
```

It fetches `registry-ca.crt` straight off the manager
(`/etc/rancher/k3s/registry-ca.crt`, the same file every Pi already
trusts - it does not generate a new CA, so a second laptop stays in the
same trust chain as the first), pins `manager0.gotham` to the manager's
current wired IP in `/etc/hosts`, and drops the CA into both
`/etc/docker/certs.d/manager0.gotham:30500/ca.crt` and
`/etc/containers/certs.d/manager0.gotham:30500/ca.crt` (Docker and
Podman). Idempotent - safe to re-run any time (e.g. the manager's wired IP
changed). It'll prompt once for this machine's local `sudo` password (not
the Pis' - those already work via the existing inventory-supplied
credentials), since writing `/etc/hosts` and `/etc/docker/certs.d` needs
root here too.

This means **a brand-new laptop never has to touch openssl or
`registry-ca.crt` by hand** - it only needs this repo cloned, ansible
installed, and the same SSH-key access to the Pis every other `make`
target here requires. Docker picks the new cert up without a restart in
most cases; restart the daemon if pushes still fail with a cert error.

### 5. Verify

```bash
curl --cacert registry-ca.crt https://manager0.gotham:30500/v2/_catalog

docker tag alpine:latest manager0.gotham:30500/test/alpine:latest
docker push manager0.gotham:30500/test/alpine:latest
```

Web UI: `https://manager0.gotham:30500/`.

## Notes

- Deploying via `make deploy` (`deployctl.sh`) works for the `apply`/`logs`/
  `delete`/`rollout` actions like any other deployment in this repo - it
  just won't create the namespace/secret for you (step 3 above still needs
  to happen first, once).
- If the cert ever needs regenerating (e.g. `registry_host` changes), redo
  step 1, re-run `ansible-playbook provision_all.yml` to push the new CA
  out, and update the k8s secret:
  `kubectl create secret tls zot-tls -n registry --cert=... --key=... --dry-run=client -o yaml | kubectl apply -f -`,
  then `kubectl rollout restart deployment/zot -n registry`.
