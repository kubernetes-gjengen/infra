#!/usr/bin/env bash
set -uo pipefail

# ---- Config (overridable via env / systemd Environment=) ----
NODE_ID="${NODE_ID:-$(hostname)}"
LOG_DIR="${LOG_DIR:-/logs}"
INTERVAL="${INTERVAL:-5}"
MAX_SIZE_KB="${MAX_SIZE_KB:-10240}"
SESSION_MARKER="${SESSION_MARKER:-/run/fieldlog/session_id}"

# One session = one start-logging/stop-logging cycle across the whole
# fleet, identified by a single id (laptop clock, not each node's own) -
# `make start-logging` sets FIELDLOG_SESSION_ID via `systemctl
# set-environment` before starting this service, so a normal run and a
# LIMIT=<host> retry to rejoin a failed node both land on the *same* id
# instead of each node minting its own from a slightly different (and
# possibly clock-drifted, see sync_time.yml) local start time.
#
# Not SESSION_MARKER for this: fieldlog-resource.service's
# RuntimeDirectory=fieldlog recreates /run/fieldlog - wiping any
# pre-existing contents - every time systemd (re)starts the unit, not just
# when it stops. A marker written by ansible *before* `systemctl start`
# raced that wipe and always lost, silently falling back to self-minting.
# The environment var lives in the systemd manager's own process, so it
# survives the directory wipe. SESSION_MARKER is still where *this script*
# publishes whatever id it resolved, every start - the network prober reads
# it to scope its own CSVs to the same session and to know whether a
# session is active at all - and it's still what a bare manual `systemctl
# start` (no env var set) falls back to reusing, then finally self-mints if
# neither is present.
# fieldlog-resource.service's RuntimeDirectory=fieldlog creates and -
# critically - removes /run/fieldlog around this script's lifetime, so the
# marker (and the "session active" signal) disappears on stop, crash, or
# SIGKILL alike, with no trap needed.
SESSION_ID="${FIELDLOG_SESSION_ID:-}"
if [ -z "$SESSION_ID" ]; then
  SESSION_ID="$(cat "$SESSION_MARKER" 2>/dev/null)"
fi
if [ -z "$SESSION_ID" ]; then
  SESSION_ID="$(date -u +%Y%m%dT%H%M%SZ)"
fi
echo "$SESSION_ID" >"$SESSION_MARKER"

LOG_FILE="$LOG_DIR/$NODE_ID-resource-$SESSION_ID.csv"
HEADER="timestamp,load1,load5,load15,mem_used_kb,mem_total_kb,temp_c,throttled"

# Single-generation rotation (current -> .old, fresh file with header) -
# bounds disk use on the SD card without needing logrotate as a dependency.
rotate_if_needed() {
  [ -f "$LOG_FILE" ] || return
  local size_kb
  size_kb=$(($(stat -c%s "$LOG_FILE") / 1024))
  if [ "$size_kb" -ge "$MAX_SIZE_KB" ]; then
    mv -f "$LOG_FILE" "$LOG_FILE.old"
  fi
}

ensure_header() {
  [ -f "$LOG_FILE" ] || echo "$HEADER" >"$LOG_FILE"
}

sample() {
  local loadavg load1 load5 load15
  loadavg=$(cut -d' ' -f1-3 /proc/loadavg)
  read -r load1 load5 load15 <<<"$loadavg"

  local mem_total_kb mem_avail_kb mem_used_kb
  mem_total_kb=$(awk '/^MemTotal:/{print $2}' /proc/meminfo)
  mem_avail_kb=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo)
  mem_used_kb=$((mem_total_kb - mem_avail_kb))

  local temp_c="" throttled=""
  if command -v vcgencmd >/dev/null 2>&1; then
    temp_c=$(vcgencmd measure_temp 2>/dev/null | grep -oE '[0-9.]+')
    throttled=$(vcgencmd get_throttled 2>/dev/null | cut -d= -f2)
  fi

  echo "$(date -Iseconds),$load1,$load5,$load15,$mem_used_kb,$mem_total_kb,$temp_c,$throttled" >>"$LOG_FILE"
}

mkdir -p "$LOG_DIR"
echo "$(date -Iseconds) INFO: starting fieldlog_resource on $NODE_ID, session $SESSION_ID (interval=${INTERVAL}s, rotate at ${MAX_SIZE_KB}KB)"

while true; do
  rotate_if_needed
  ensure_header
  sample
  sleep "$INTERVAL"
done
