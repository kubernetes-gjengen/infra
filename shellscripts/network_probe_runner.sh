#!/usr/bin/env bash

# === Configuration ===
SCRIPT_PATH="/home/pi/network_prober.sh"
MIN_BACKOFF=10     # seconds
MAX_BACKOFF=120    # seconds

if [[ ! -x "$SCRIPT_PATH" ]]; then
    echo "Error: $SCRIPT_PATH not found or not executable"
    exit 1
fi

echo "Starting network prober runner..."
echo "Backoff range: ${MIN_BACKOFF}s - ${MAX_BACKOFF}s"

while true; do
    echo "----------------------------------------"
    echo "Running network prober at $(date)"

    sudo "$SCRIPT_PATH"

    # Random backoff
    backoff=$(( RANDOM % (MAX_BACKOFF - MIN_BACKOFF + 1) + MIN_BACKOFF ))
    echo "Sleeping for ${backoff}s..."
    sleep "$backoff"
done
