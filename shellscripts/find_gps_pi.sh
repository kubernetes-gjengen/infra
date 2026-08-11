#!/usr/bin/env bash
set -uo pipefail

# Checks a list of Pis for gpsd being installed and a GPS receiver attached.
# Usage: find_gps_pi.sh host1 host2 ... | find_gps_pi.sh -f hosts.txt
# Env: PI_SSH_USER, PI_SSH_PASSWORD, TIMEOUT (seconds per host).

SSH_USER="${PI_SSH_USER:-pi}"
SSH_PASS="${PI_SSH_PASSWORD:-raspberry}"
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

qualify() {
  case "$1" in
  *.* | *:*) echo "$1" ;;
  *) echo "$1.local" ;;
  esac
}

# These Pis authenticate by password, not key.
if command -v sshpass >/dev/null 2>&1; then
  ssh_run() { sshpass -p "$SSH_PASS" ssh -o StrictHostKeyChecking=accept-new "$@"; }
else
  echo "find_gps_pi.sh: sshpass not found - falling back to key-based auth only" >&2
  ssh_run() { ssh -o StrictHostKeyChecking=accept-new -o BatchMode=yes "$@"; }
fi

# dpkg, not `command -v gpsd`: non-interactive ssh sessions get a reduced PATH that excludes /usr/sbin.
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

  # No STATUS: marker means ssh itself never got there.
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
