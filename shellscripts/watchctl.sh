#!/usr/bin/env bash
set -uo pipefail

# Interactive picker for live "watch" views into the cluster - each one
# streams continuously until Ctrl-C. Add more entries to TARGETS and the
# dispatch case below as new ones come up.
#
# Usage:
#   watchctl.sh             fzf-pick a target
#   watchctl.sh pods        pick this specific target directly

SSH_USER="${SSH_USER:-pi}"
SSH_PASS="${SSH_PASS:-raspberry}"

TARGETS=(scheduler pods nodes services)

usage() {
  echo "Usage: $(basename "$0") [${TARGETS[*]}]"
  exit 1
}

for dep in fzf kubectl watch; do
  command -v "$dep" >/dev/null 2>&1 || {
    echo "watchctl: missing dependency '$dep'" >&2
    exit 1
  }
done

target=""
if [ $# -gt 0 ]; then
  case "$1" in
  -h | --help) usage ;;
  *)
    for t in "${TARGETS[@]}"; do
      [ "$1" = "$t" ] && target="$1" && break
    done
    [ -z "$target" ] && {
      echo "watchctl: unknown target '$1'" >&2
      usage
    }
    ;;
  esac
fi

if [ -z "$target" ]; then
  target=$(printf '%s\n' "${TARGETS[@]}" |
    fzf --prompt="watch> " --height='40%' --layout=reverse) || exit 0
  [ -z "$target" ] && exit 0
fi

# These Pis authenticate by password, not key (same convention as
# find_gps_pi.sh) - -t forces a pty so a live tail like `journalctl -f`
# streams normally over ssh instead of buffering.
if command -v sshpass >/dev/null 2>&1; then
  ssh_run() { sshpass -p "$SSH_PASS" ssh -t -o StrictHostKeyChecking=accept-new "$@"; }
else
  echo "watchctl: sshpass not found - falling back to key-based auth only" >&2
  ssh_run() { ssh -t -o StrictHostKeyChecking=accept-new "$@"; }
fi

case "$target" in
scheduler)
  echo "==> watching k8-scheduler.service on manager0.local (Ctrl-C to stop)"
  ssh_run "$SSH_USER@manager0.local" journalctl -u k8-scheduler.service -f
  ;;
pods)
  # default holds the app deployments; registry holds the Zot registry
  # (its own namespace - see registry/zot.yml) - plain `kubectl get pods`
  # only shows default, so list both explicitly.
  exec watch -n 2 'kubectl get pods -n default -o wide; echo; kubectl get pods -n registry -o wide'
  ;;
nodes)
  exec watch -n 2 kubectl get nodes -o wide
  ;;
services)
  exec watch -n 2 kubectl get services -o wide
  ;;
esac
