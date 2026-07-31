#!/usr/bin/env bash
set -uo pipefail

# ---- Config (overridable via env / systemd Environment=) ----
GRPC_HOST="${GRPC_HOST:-192.168.42.1}"
GRPC_PORT="${GRPC_PORT:-30042}"
PROTO_FILE="${PROTO_FILE:-/home/pi/message.proto}"
NODE_ID="${NODE_ID:-$(hostname)}"
BAT_IFACE="${BAT_IFACE:-bat0}"
LATENCY_INTERVAL="${LATENCY_INTERVAL:-5}" # seconds between latency cycles
THROUGHPUT_EVERY="${THROUGHPUT_EVERY:-6}" # throughput every Nth cycle (6*5s = 30s)
PING_COUNT="${PING_COUNT:-3}"
IPERF_PORT="${IPERF_PORT:-5201}"
IPERF_DURATION="${IPERF_DURATION:-3}"
LOG_DIR="${LOG_DIR:-/logs}"
MAX_SIZE_KB="${MAX_SIZE_KB:-10240}"
LOG_ALL_ROUTES="${LOG_ALL_ROUTES:-false}" # false = only the chosen (starred) nexthop per destination; true = every candidate
SESSION_MARKER="${SESSION_MARKER:-/run/fieldlog/session_id}"

cycle=0
declare -A last_throughput
declare -A last_latency
LATENCY_CACHE="/tmp/network_prober_latency"
mkdir -p "$LATENCY_CACHE"

# Local durability alongside the MQTT publish below - maviz can't be trusted
# to have caught everything if this node drops off the mesh mid-experiment,
# so every value sent over MQTT is also appended here independent of it.
#
# This script itself runs continuously (Restart=always, no start/stop
# toggle) so the live MQTT publish never depends on remembering to start a
# session - but the CSV *files* are still scoped to one start-logging/
# stop-logging session, same as fieldlog-resource.service, so they're
# comparable per-experiment logs rather than one growing file. LOGGING_ACTIVE,
# LOG_FILE and ROUTE_LOG_FILE are (re)computed every loop iteration from
# SESSION_MARKER - see update_session() below - since a session can start,
# stop, and start again while this process keeps running.
HEADER="timestamp,from,to,latency_ms,throughput_mbps"

# batman-adv's chosen nexthop per destination (the starred row in `batctl o`)
# - shows which neighbor batman is actually routing each destination through,
# independent of the latency/throughput samples above.
ROUTE_HEADER="timestamp,node,destination,last_seen,quality,nexthop,outgoing_if,chosen"

LOGGING_ACTIVE=false
LOG_FILE=""
ROUTE_LOG_FILE=""

mkdir -p "$LOG_DIR"

# ---- Helpers ----

# Single-generation rotation (current -> .old, fresh file with header) -
# checked once per outer loop iteration (not inside the parallel per-neighbor
# probes) so concurrent probes never race each other into double-rotating.
rotate_if_needed() {
  local file="$1"
  [ -f "$file" ] || return
  local size_kb
  size_kb=$(($(stat -c%s "$file") / 1024))
  if [ "$size_kb" -ge "$MAX_SIZE_KB" ]; then
    mv -f "$file" "$file.old"
  fi
}

ensure_header() {
  local file="$1" header="$2"
  [ -f "$file" ] || echo "$header" >"$file"
}

# Re-derive LOGGING_ACTIVE/LOG_FILE/ROUTE_LOG_FILE from SESSION_MARKER once
# per loop iteration. Session id comes from fieldlog_resource.sh so both
# scripts' files for the same experiment share a filename suffix.
update_session() {
  if [ -f "$SESSION_MARKER" ]; then
    local session_id
    session_id="$(<"$SESSION_MARKER")"
    if [ -n "$session_id" ]; then
      LOGGING_ACTIVE=true
      LOG_FILE="$LOG_DIR/$NODE_ID-network-$session_id.csv"
      ROUTE_LOG_FILE="$LOG_DIR/$NODE_ID-route-$session_id.csv"
      return
    fi
  fi
  LOGGING_ACTIVE=false
}

log_csv() {
  # Small single-line appends stay under PIPE_BUF, so concurrent probes
  # writing to the same file (probe_latency runs one per neighbor in
  # parallel) don't interleave into corrupt lines.
  [ "$LOGGING_ACTIVE" = true ] || return
  echo "$(date -Iseconds),$NODE_ID,$1,$2,$3" >>"$LOG_FILE"
}

get_originators() {
  # Raw `batctl o` output, captured once per cycle and reused by both
  # get_neighbors and log_routes below - avoids a second batctl invocation.
  batctl -m "$BAT_IFACE" o 2>/dev/null
}

get_neighbors() {
  # batctl resolves MACs to names via /etc/bat-hosts; extract best-path (*) entries
  echo "$1" | awk '$1 == "*" {print $2}'
}

log_routes() {
  # Default: only the starred row per destination (the nexthop batman
  # actually routes through). LOG_ALL_ROUTES=true also logs every other
  # candidate nexthop for that destination - much higher row count, off by
  # default. Data rows are identified by a "(NNN)" quality field rather than
  # position, so this doesn't accidentally match the banner/column-header
  # lines `batctl o` prints above the table.
  #
  # Field layout differs by one column depending on the leading "*":
  #   starred:     $1=*  $2=dest $3=last-seen $4=(quality) $5=nexthop $7=iface]
  #   non-starred: $1=dest $2=last-seen $3=(quality) $4=nexthop $6=iface]
  [ "$LOGGING_ACTIVE" = true ] || return
  local ts
  ts="$(date -Iseconds)"
  echo "$1" | awk -v ts="$ts" -v node="$NODE_ID" -v all="$LOG_ALL_ROUTES" '
    /\([0-9]+\)/ {
      starred = ($1 == "*")
      if (starred) { dest = $2; seen = $3; q = $4; nh = $5; oif = $7 }
      else         { dest = $1; seen = $2; q = $3; nh = $4; oif = $6 }
      if (all == "true" || starred) {
        gsub(/[()]/, "", q)
        gsub(/\]/, "", oif)
        print ts "," node "," dest "," seen "," q "," nh "," oif "," (starred ? "true" : "false")
      }
    }' >>"$ROUTE_LOG_FILE"
}

neighbor_to_ip() {
  getent hosts "$1" 2>/dev/null | awk '{print $1; exit}'
}

# send_grpc() {
#   if ! grpcurl -plaintext \
#     -import-path "$(dirname "$PROTO_FILE")" \
#     -proto "$(basename "$PROTO_FILE")" \
#     -d "$1" \
#     "${GRPC_HOST}:${GRPC_PORT}" \
#     links.LinkService/SendData >/dev/null 2>&1; then
#     echo "$(date -Iseconds) WARN: grpcurl failed" >&2
#   fi
# }
send_json() {
  mosquitto_pub -h "127.0.0.1" -p 31883 -t network/linkdata -m $1
}

probe_latency() {
  local neighbor="$1" out avg_ms
  out="$(timeout 10 batctl -m "$BAT_IFACE" ping -c "$PING_COUNT" "$neighbor" 2>/dev/null)"
  [ -z "$out" ] && {
    echo "$(date -Iseconds) WARN: no ping from $neighbor" >&2
    return
  }

  avg_ms="$(echo "$out" | grep -oE 'time=[0-9.]+' | cut -d= -f2 |
    awk '{s+=$1; n++} END{if (n) printf "%.0f", s/n}')"

  if [ -z "$avg_ms" ]; then
    echo "$(date -Iseconds) WARN: could not parse latency from $neighbor" >&2
    return
  fi
  [ "$avg_ms" -eq 0 ] && avg_ms=1

  echo "$avg_ms" >"$LATENCY_CACHE/$neighbor"
  local tp="${last_throughput[$neighbor]:-0}"
  # send_grpc "{\"from\":\"$NODE_ID\",\"to\":\"$neighbor\",\"latency\":$avg_ms,\"throughput\":$tp,\"timestamp\":$(date +%s)}"
  send_json "{\"from\":\"$NODE_ID\",\"to\":\"$neighbor\",\"latency\":$avg_ms,\"throughput\":$tp,\"timestamp\":$(date +%s)}"
  log_csv "$neighbor" "$avg_ms" "$tp"
}

probe_throughput() {
  local neighbor="$1" ip="$2" out bps
  out="$(iperf3 -c "$ip" -p "$IPERF_PORT" -t "$IPERF_DURATION" -J 2>/dev/null)"
  [ -z "$out" ] && {
    echo "$(date -Iseconds) WARN: iperf3 failed to $ip ($neighbor)" >&2
    return
  }

  local mbps
  mbps="$(echo "$out" | jq -r '(.end.sum_sent.bits_per_second // .end.sum.bits_per_second // 0) / 1000000')"
  last_throughput[$neighbor]="${mbps:-0}"

  local lat="${last_latency[$neighbor]:-0}"
  # send_grpc "{\"from\":\"$NODE_ID\",\"to\":\"$neighbor\",\"latency\":$lat,\"throughput\":${mbps:-0},\"timestamp\":$(date +%s)}"
  send_json "{\"from\":\"$NODE_ID\",\"to\":\"$neighbor\",\"latency\":$lat,\"throughput\":${mbps:-0},\"timestamp\":$(date +%s)}"
  log_csv "$neighbor" "$lat" "${mbps:-0}"
}

# ---- Main loop ----

echo "$(date -Iseconds) INFO: starting on $NODE_ID (${GRPC_HOST}:${GRPC_PORT})"

while true; do
  cycle=$((cycle + 1))
  update_session
  if [ "$LOGGING_ACTIVE" = true ]; then
    rotate_if_needed "$LOG_FILE"
    ensure_header "$LOG_FILE" "$HEADER"
    rotate_if_needed "$ROUTE_LOG_FILE"
    ensure_header "$ROUTE_LOG_FILE" "$ROUTE_HEADER"
  fi

  originators="$(get_originators)"
  mapfile -t neighbors < <(get_neighbors "$originators")
  log_routes "$originators"

  [ "${#neighbors[@]}" -eq 0 ] &&
    echo "$(date -Iseconds) WARN: no neighbors found" >&2

  for neighbor in "${neighbors[@]}"; do
    [ -z "$neighbor" ] && continue
    probe_latency "$neighbor" &
  done
  wait

  for neighbor in "${neighbors[@]}"; do
    [ -f "$LATENCY_CACHE/$neighbor" ] &&
      last_latency[$neighbor]=$(<"$LATENCY_CACHE/$neighbor")
  done

  if ((cycle % THROUGHPUT_EVERY == 0)); then
    sleep $((RANDOM % 15))
    for neighbor in "${neighbors[@]}"; do
      [ -z "$neighbor" ] && continue
      local_ip="$neighbor".gotham
      [ -z "$local_ip" ] &&
        {
          echo "$(date -Iseconds) WARN: no IP for $neighbor, skipping throughput" >&2
          continue
        }
      probe_throughput "$neighbor" "$local_ip"
    done
  fi

  sleep "$LATENCY_INTERVAL"
done
