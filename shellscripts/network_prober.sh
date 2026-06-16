#!/usr/bin/env bash

# === Configuration ===
GRPC_HOST="127.0.0.1:50051"
PROTO_FILE="message.proto"
PROTO_IMPORT_PATH=/home/pi
TMP_JSON="/tmp/links.json"
PING_COUNT=5


# === 0. Setup portforwarding into K8 cluster ===
KUBECONFIG=/home/pi/kubeconfig kubectl port-forward pod/apiserver-54c88c4c87-qjj4b 50051:50051 &
K8_FORWARDING_PID=$!
sleep 2

# === 1. Query existing link data via grpcurl ===
echo "Querying existing link data..."
grpcurl -plaintext -d '{}' -import-path "$PROTO_IMPORT_PATH" -proto "$PROTO_FILE" "$GRPC_HOST" links.LinkService/GetAllLinks > "$TMP_JSON"

# === 2. Get hostname and test links to neighbours ===
HOST=$(hostname)
echo "Current host: $HOST"

# Get neighbours from batman-adv
echo "Getting neighbours via batctl..."
neighbours=$(batctl n | awk 'NR>2 {print $2}' | sort -u)

# Function to resolve neighbour to a reachable target
resolve_target() {
    local neigh=$1
    sudo batctl t "$neigh" 2>/dev/null | awk 'NR==1 {print $1}'
}

# Function to measure throughput for a neighbour
# Always returns Mbps (float)
measure_throughput() {
    local neigh=$1

    local result value unit


    result=""
    until [[ -n "$result" ]]; do
        result=$(sudo batctl tp "$neigh" -t 500 2>/dev/null)
        [[ -z "$result" ]] && sleep 3
    done

    # Example lines handled:
    # Throughput: 2.87 MB/s (24.09 Mbps)
    # Throughput: 850 kbit/s
    # Throughput: 1.97 Mbit/s

    # Prefer Mbps if present in parentheses
    if echo "$result" | grep -q "Mbps"; then
        value=$(echo "$result" | sed -n 's/.*(\([0-9.]*\) Mbps).*/\1/p')
        echo "${value:-0}"
        return
    elif echo "$result" | grep -q "Kbps"; then
        value=$(echo "$result" | sed -n 's/.*(\([0-9.]*\) Kbps).*/\1/p')
        value=$(echo "scale=4; $value / 1000" | bc)
        echo "${value:-0}"
        return
    fi
    echo 0
}

measure_latency() {
    local target=$1

    if [[ -z "$target" ]]; then
        echo "0"
        return
    fi
    sudo batctl meshif bat0 p "$target" -c "$PING_COUNT" 2>/dev/null \
        | tail -1 \
        | awk -F'/' '{print $5}' \
        | awk '{printf "%.0f", $1}'
}

# === 3. Calculate average (placeholder function) ===
average() {
    local a=$1
    local b=$2
    echo "scale=2; ($a + $b) / 2" | bc
}

# === Process each neighbour ===
for neigh in $neighbours; do
  echo "Processing neighbour: $neigh"


    target=$(resolve_target "$neigh")


    # === Existing data ===
    existing_thr=$(jq -r --arg FROM "$HOST" --arg TO "$neigh" '.links[] | select(.from==$FROM and .to==$TO) | .throughput' "$TMP_JSON")
    existing_lat=$(jq -r --arg FROM "$HOST" --arg TO "$neigh" '.links[] | select(.from==$FROM and .to==$TO) | .latency' "$TMP_JSON")


    existing_thr=${existing_thr:-0}
    existing_lat=${existing_lat:-0}


    # === Measurements ===
    measured_thr=$(measure_throughput "$target")
    echo "measured thr $measured_thr"
    measured_thr=${measured_thr:-0}


    measured_lat=$(measure_latency "$target")
    measured_lat=${measured_lat:-0}


    # === Updated values (rounded to int) ===
    updated_thr=$(printf $(average "$existing_thr" "$measured_thr"))
    updated_lat=$(printf "%.0f" $(average "$existing_lat" "$measured_lat"))


    echo "Existing throughput: $existing_thr"
    echo "Measured throughput: $measured_thr"
    echo "Updated throughput: $updated_thr"


    echo "Existing latency: $existing_lat"
    echo "Measured latency: $measured_lat"
    echo "Updated latency: $updated_lat"
    # === 4. Save back updated data ===
    echo "Sending updated data via grpcurl..."
    grpcurl -plaintext \
        -d "{\"from\": \"$HOST\", \"to\": \"$neigh\", \"latency\": $measured_lat, \"throughput\": $updated_thr}" \
        -import-path "$PROTO_IMPORT_PATH" \
        -proto "$PROTO_FILE" \
        "$GRPC_HOST" links.LinkService/SendData

done

kill $K8_FORWARDING_PID
echo "Done."
