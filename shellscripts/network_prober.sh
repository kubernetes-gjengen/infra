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

cycle=0
declare -A last_throughput
declare -A last_latency
LATENCY_CACHE="/tmp/network_prober_latency"
mkdir -p "$LATENCY_CACHE"

# ---- Helpers ----

get_neighbors() {
	# batctl resolves MACs to names via /etc/bat-hosts; extract best-path (*) entries
	batctl -m "$BAT_IFACE" o 2>/dev/null | awk '$1 == "*" {print $2}'
}

neighbor_to_ip() {
	getent hosts "$1" 2>/dev/null | awk '{print $1; exit}'
}

send_grpc() {
	if ! grpcurl -plaintext \
		-import-path "$(dirname "$PROTO_FILE")" \
		-proto "$(basename "$PROTO_FILE")" \
		-d "$1" \
		"${GRPC_HOST}:${GRPC_PORT}" \
		links.LinkService/SendData >/dev/null 2>&1; then
		echo "$(date -Iseconds) WARN: grpcurl failed" >&2
	fi
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

	echo "$avg_ms" > "$LATENCY_CACHE/$neighbor"
	local tp="${last_throughput[$neighbor]:-0}"
	send_grpc "{\"from\":\"$NODE_ID\",\"to\":\"$neighbor\",\"latency\":$avg_ms,\"throughput\":$tp,\"timestamp\":$(date +%s)}"
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
	send_grpc "{\"from\":\"$NODE_ID\",\"to\":\"$neighbor\",\"latency\":$lat,\"throughput\":${mbps:-0},\"timestamp\":$(date +%s)}"
}

# ---- Main loop ----

echo "$(date -Iseconds) INFO: starting on $NODE_ID (${GRPC_HOST}:${GRPC_PORT})"

while true; do
	cycle=$((cycle + 1))
	mapfile -t neighbors < <(get_neighbors)

	[ "${#neighbors[@]}" -eq 0 ] &&
		echo "$(date -Iseconds) WARN: no neighbors found" >&2

	for neighbor in "${neighbors[@]}"; do
		[ -z "$neighbor" ] && continue
		probe_latency "$neighbor" &
	done
	wait

	for neighbor in "${neighbors[@]}"; do
		[ -f "$LATENCY_CACHE/$neighbor" ] \
			&& last_latency[$neighbor]=$(< "$LATENCY_CACHE/$neighbor")
	done

	if ((cycle % THROUGHPUT_EVERY == 0)); then
		sleep $((RANDOM % 15))
		for neighbor in "${neighbors[@]}"; do
			[ -z "$neighbor" ] && continue
			local_ip="$(neighbor_to_ip "$neighbor")"
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
