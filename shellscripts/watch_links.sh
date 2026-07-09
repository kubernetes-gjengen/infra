#!/usr/bin/env bash
set -uo pipefail
# JSON always uses '.' as the decimal separator; force it regardless of the
# operator's locale so printf's %f formatting doesn't choke on it (e.g. a
# comma-decimal locale rejects "94.328" as "invalid number").
export LC_NUMERIC=C

# Live table of mesh link latency/throughput, sourced from the same
# network/linkdata MQTT topic network_prober.sh (on each Pi) publishes to.
# The broker is a k3s NodePort service, reachable from any node - including
# a laptop on the wired setup subnet - at <any-node>:MQTT_PORT.
#
# Usage: watch_links.sh [refresh_seconds]

REFRESH="${1:-3}"
MQTT_HOST="${MQTT_HOST:-manager0.local}"
MQTT_PORT="${MQTT_PORT:-31883}"
MQTT_TOPIC="network/linkdata"

case "$REFRESH" in
'-h' | '--help')
  echo "Usage: $(basename "$0") [refresh_seconds]  (default: 3)"
  echo "Env: MQTT_HOST (default manager0.local), MQTT_PORT (default 31883)"
  exit 0
  ;;
*[!0-9]* | '')
  echo "watch_links: refresh_seconds must be a positive integer, got '$REFRESH' - using 3" >&2
  REFRESH=3
  ;;
esac

for dep in mosquitto_sub jq; do
  command -v "$dep" >/dev/null 2>&1 || {
    echo "watch_links: missing dependency '$dep'" >&2
    exit 1
  }
done

# manager0 -> m0, worker12 -> w12, anything else passed through unshortened.
shorten() {
  case "$1" in
  manager*) echo "m${1#manager}" ;;
  worker*) echo "w${1#worker}" ;;
  *) echo "$1" ;;
  esac
}

declare -A LATENCY
declare -A THROUGHPUT
declare -A SEEN_AT

render() {
  clear
  printf 'watch_links  %s  (refresh %ss, source %s:%s/%s)\n\n' \
    "$(date '+%H:%M:%S')" "$REFRESH" "$MQTT_HOST" "$MQTT_PORT" "$MQTT_TOPIC"

  if [ "${#LATENCY[@]}" -eq 0 ]; then
    printf 'Waiting for link data...\n'
    return
  fi

  printf '%-6s %-6s %10s %14s %8s\n' "FROM" "TO" "LATENCY" "THROUGHPUT" "AGE"
  local now=$(date +%s) key from to
  for key in "${!LATENCY[@]}"; do
    from="${key%%|*}"
    to="${key#*|}"
    printf '%-6s %-6s %8sms %11.1fMbps %6ss\n' \
      "$(shorten "$from")" "$(shorten "$to")" \
      "${LATENCY[$key]}" "${THROUGHPUT[$key]:-0}" "$((now - SEEN_AT[$key]))"
  done | sort -V
}

trap 'printf "\n"; exit 0' INT TERM

last_render=0
while true; do
  if IFS= read -r -t "$REFRESH" line; then
    from=$(jq -r '.from // empty' <<<"$line" 2>/dev/null)
    to=$(jq -r '.to // empty' <<<"$line" 2>/dev/null)
    if [ -n "$from" ] && [ -n "$to" ]; then
      key="${from}|${to}"
      lat=$(jq -r '.latency // empty' <<<"$line" 2>/dev/null)
      tp=$(jq -r '.throughput // empty' <<<"$line" 2>/dev/null)
      [ -n "$lat" ] && LATENCY["$key"]="$lat"
      [ -n "$tp" ] && THROUGHPUT["$key"]="$tp"
      SEEN_AT["$key"]=$(date +%s)
    fi
  fi

  now=$(date +%s)
  if ((now - last_render >= REFRESH)); then
    render
    last_render=$now
  fi
done < <(mosquitto_sub -h "$MQTT_HOST" -p "$MQTT_PORT" -t "$MQTT_TOPIC")
