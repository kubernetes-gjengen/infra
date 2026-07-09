#!/usr/bin/env bash
set -uo pipefail

# Checks a list of Pis for gpsd being installed and a GPS receiver attached.
#
# Usage:
#   find_gps_pi.sh host1 host2 ...
#   find_gps_pi.sh -f hosts.txt
#
# Hosts can be given as short names (manager0, worker3, ...) - they're
# resolved via mDNS as <host>.local, same convention as watch_links.sh.
#
# Env: SSH_USER (default: pi), SSH_PASS (default: raspberry, this project's
# default Pi credential - see discover.py), TIMEOUT seconds per host (default: 5)

SSH_USER="${SSH_USER:-pi}"
SSH_PASS="${SSH_PASS:-raspberry}"
TIMEOUT="${TIMEOUT:-5}"
hosts=()

usage() {
  echo "Usage: $(basename "$0") [-u ssh-user] [-t timeout] host [host ...]"
  echo "       $(basename "$0") [-u ssh-user] [-t timeout] -f hosts.txt"
  exit 1
}

while getopts "u:t:f:h" opt; do
  case "$opt" in
  u) SSH_USER="$OPTARG" ;;
  t) TIMEOUT="$OPTARG" ;;
  f) mapfile -t hosts <"$OPTARG" ;;
  h) usage ;;
  *) usage ;;
  esac
done
shift $((OPTIND - 1))
hosts+=("$@")

[ "${#hosts[@]}" -eq 0 ] && usage

# manager0 -> manager0.local, but leave already-qualified names alone.
qualify() {
  case "$1" in
  *.* | *:*) echo "$1" ;;
  *) echo "$1.local" ;;
  esac
}

# These Pis authenticate by password, not key (same default as the rest of
# this repo - see discover.py's SSH_PASSWORD). -o BatchMode=yes would refuse
# to even prompt for one, so every ssh call failed auth before the remote
# command ever ran - wrap with sshpass instead when it's available.
if command -v sshpass >/dev/null 2>&1; then
  ssh_run() { sshpass -p "$SSH_PASS" ssh -o StrictHostKeyChecking=accept-new "$@"; }
else
  echo "find_gps_pi.sh: sshpass not found - falling back to key-based auth only" >&2
  ssh_run() { ssh -o StrictHostKeyChecking=accept-new -o BatchMode=yes "$@"; }
fi

# Installed and "the service is up" are separate, independently-failing
# conditions (gpsd can be apt-installed but never started/enabled) - check
# each explicitly rather than guessing from gpspipe's error text, which is
# fragile (wording-dependent) and conflated both cases into one message.
# dpkg, not `command -v gpsd`: non-interactive ssh sessions get a reduced
# PATH that excludes /usr/sbin, where the gpsd binary actually lives -
# command -v would report "not installed" even when it genuinely is.
# -w turns on gpsd's watch mode (JSON), which reports a DEVICES list right
# away instead of waiting for a fix. -x makes gpspipe exit itself after N
# seconds so we don't hang on a Pi with no GPS attached.
remote_cmd="
if ! dpkg -s gpsd >/dev/null 2>&1; then
  echo STATUS:NOT_INSTALLED
elif ! systemctl is-active --quiet gpsd; then
  echo STATUS:NOT_RUNNING
else
  echo STATUS:RUNNING
  timeout $TIMEOUT gpspipe -w -x 2 2>&1
fi
"

for host in "${hosts[@]}"; do
  [ -z "$host" ] && continue
  target=$(qualify "$host")
  printf '%-20s ' "$host"

  output=$(ssh_run -o ConnectTimeout="$TIMEOUT" "$SSH_USER@$target" "$remote_cmd" 2>&1)

  # The remote script always echoes exactly one STATUS: marker on success,
  # so its absence means ssh itself never got there (auth/DNS/connection
  # failure) - far more reliable than guessing from exit status/emptiness.
  case "$output" in
  *STATUS:NOT_INSTALLED*)
    echo "ERROR: gpsd not installed"
    continue
    ;;
  *STATUS:NOT_RUNNING*)
    echo "ERROR: gpsd installed but service not running"
    continue
    ;;
  *STATUS:RUNNING*) ;;
  *)
    echo "ERROR: ssh failed ($(echo "$output" | tail -1 | tr -d '\r'))"
    continue
    ;;
  esac

  if ! echo "$output" | grep -q '"class":"VERSION"'; then
    echo "ERROR: gpsd running but gpspipe got no response"
    continue
  fi

  devices=$(echo "$output" | grep -o '"path":"[^"]*"' | sort -u)

  if [ -n "$devices" ]; then
    echo "GPS FOUND -> $(echo "$devices" | tr '\n' ' ')"
  else
    echo "no GPS attached"
  fi
done
