#!/usr/bin/env bash
set -uo pipefail

# Interactive picker for Kubernetes deployments across this repo and its
# sibling repos (../*  relative to this script's location, i.e. ~/repos/ffi).
#
# A "deployment" is any file containing `kind: Deployment` or
# `kind: DaemonSet` that grep can find. If the owning repo has a Makefile
# with a target matching the chosen
# action (apply/logs/delete/build/rollout), that's used - most deployments
# already have one (see object-detection/Makefile, gps-client/Makefile for
# the convention). Otherwise falls back to a direct kubectl equivalent for
# that one specific action (build has no generic fallback - there's no way
# to infer an image name/registry from nothing).
#
# Usage:
#   deployctl.sh                 fzf-pick deployment, then fzf-pick action
#   deployctl.sh apply|logs|delete|build|rollout
#                                 fzf-pick deployment only, run that action

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SIBLINGS_ROOT="$(cd "$INFRA_ROOT/.." && pwd)"

ACTIONS=(apply logs delete build rollout)

usage() {
  echo "Usage: $(basename "$0") [apply|logs|delete|build|rollout]"
  exit 1
}

for dep in fzf kubectl; do
  command -v "$dep" >/dev/null 2>&1 || {
    echo "deployctl: missing dependency '$dep'" >&2
    exit 1
  }
done

action=""
if [ $# -gt 0 ]; then
  case "$1" in
  apply | logs | delete | build | rollout) action="$1" ;;
  -h | --help) usage ;;
  *)
    echo "deployctl: unknown action '$1'" >&2
    usage
    ;;
  esac
fi

# --- Discover deployments -------------------------------------------------
# One row per (repo, manifest file) pair:
#   DISPLAY \t REPO_DIR \t MAKEFILE(or empty) \t MANIFEST_FILE \t DEPLOYMENT_NAME \t KIND

candidates=("$INFRA_ROOT")
for d in "$SIBLINGS_ROOT"/*/; do
  d="${d%/}"
  [ "$d" = "$INFRA_ROOT" ] && continue
  candidates+=("$d")
done

rows=()
for repo in "${candidates[@]}"; do
  repo_name="$(basename "$repo")"
  makefile=""
  [ -f "$repo/Makefile" ] && makefile="$repo/Makefile"

  # /templates/ excludes Helm chart templates - they use Go template syntax
  # (e.g. {{ .Release.Name }}) instead of literal values, so they're not
  # directly kubectl-applyable and need `helm template`/`helm install`.
  mapfile -t manifests < <(grep -rlE "^kind: (Deployment|DaemonSet)" \
    --include="*.yml" --include="*.yaml" "$repo" 2>/dev/null |
    grep -v -e '/\.git/' -e '/node_modules/' -e '/templates/')

  [ "${#manifests[@]}" -eq 0 ] && continue
  multi=0
  [ "${#manifests[@]}" -gt 1 ] && multi=1

  for m in "${manifests[@]}"; do
    # A file can hold more than one `kind: Deployment`/`kind: DaemonSet`
    # block (e.g. an app plus a supporting service like a message broker).
    # Prefer the one whose name matches the repo, else take the first one
    # found.
    mapfile -t dep_entries < <(awk '
      /^kind: (Deployment|DaemonSet)/ { k=$2; f=1; next }
      f && /^[[:space:]]+name:[[:space:]]*/ {
        sub(/^[[:space:]]+name:[[:space:]]*/, "")
        print k "\t" $0
        f=0
      }
    ' "$m")

    dep_name="" kind=""
    for e in "${dep_entries[@]}"; do
      n="${e#*$'\t'}"
      [ "$n" = "$repo_name" ] && dep_name="$n" && kind="${e%%$'\t'*}" && break
    done
    if [ -z "$dep_name" ]; then
      dep_name="${dep_entries[0]#*$'\t'}"
      kind="${dep_entries[0]%%$'\t'*}"
      [ -z "$dep_name" ] && dep_name="$repo_name"
    fi

    if [ "$multi" -eq 1 ]; then
      display="$repo_name/$(basename "${m%.*}")"
    else
      display="$repo_name"
    fi

    rows+=("$display"$'\t'"$repo"$'\t'"$makefile"$'\t'"$m"$'\t'"$dep_name"$'\t'"$kind")
  done
done

[ "${#rows[@]}" -eq 0 ] && {
  echo "deployctl: no Kubernetes Deployments found under $SIBLINGS_ROOT" >&2
  exit 1
}

# --- Pick the deployment ---------------------------------------------------

selection=$(printf '%s\n' "${rows[@]}" | fzf \
  --delimiter='\t' --with-nth=1 \
  --prompt="deployment> " --height='60%' --layout=reverse \
  --preview='cat {4}' --preview-window=right:60%) || exit 0
[ -z "$selection" ] && exit 0

IFS=$'\t' read -r disp repo_dir makefile manifest dep_name kind <<<"$selection"
kind_lc="$(printf '%s' "$kind" | tr '[:upper:]' '[:lower:]')"

# --- Pick the action, if not given on the command line ---------------------

if [ -z "$action" ]; then
  action=$(printf '%s\n' "${ACTIONS[@]}" |
    fzf --prompt="action> " --height='40%' --layout=reverse) || exit 0
  [ -z "$action" ] && exit 0
fi

if [ "$action" = delete ]; then
  read -r -p "Delete '$disp' ($dep_name)? [y/N] " ans
  case "$ans" in
  y | Y) ;;
  *)
    echo "Aborted."
    exit 1
    ;;
  esac
fi

# --- Dispatch: prefer the repo's own Makefile target, else kubectl direct --

if [ -n "$makefile" ] && grep -q "^${action}:" "$makefile"; then
  echo "==> make $action   ($repo_dir)"
  (cd "$repo_dir" && exec make "$action")
  exit $?
fi

echo "==> kubectl $action   ($disp, no '$action' target in Makefile - using kubectl directly)"
case "$action" in
apply)
  exec kubectl apply -f "$manifest"
  ;;
logs)
  exec kubectl logs -f "$kind_lc/$dep_name"
  ;;
rollout)
  exec kubectl rollout restart "$kind_lc/$dep_name"
  ;;
delete)
  exec kubectl delete -f "$manifest"
  ;;
build)
  echo "deployctl: no build target for '$disp' - no Makefile build recipe and no way to infer an image name" >&2
  exit 1
  ;;
esac
