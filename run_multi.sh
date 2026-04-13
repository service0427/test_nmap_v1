#!/bin/bash
# test_nmap_v1: Minimal Multi Device Parallel Runner

BASE_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$BASE_DIR" || exit 1

TARGET_ID=""
RESET_MODE=""
NO_FILTER=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --reset) RESET_MODE="--reset"; shift ;;
        --original) NO_FILTER="--original"; shift ;;
        --id) TARGET_ID="$2"; shift 2 ;;
        *) shift ;;
    esac
done

CONFIG_FILE="api/devices.json"

if [ ! -f "$CONFIG_FILE" ]; then
    echo "[-] Cannot find $CONFIG_FILE"
    exit 1
fi

DEVICE_IDS=$(jq -r '.devices[].id' "$CONFIG_FILE")

echo "============================================================"
echo "   NMAP V1 MULTI RUNNER"
echo "   Target Route: ${TARGET_ID:-Manual}"
echo "   Devices: $(echo "$DEVICE_IDS" | wc -w)"
echo "============================================================"

declare -a PIDS

cleanup() {
    echo -e "\n[Multi] Graceful shutdown initiated..."
    # Killing the process group for each child gracefully
    for pid in "${PIDS[@]}"; do
        kill -INT "$pid" 2>/dev/null
    done
    wait
    echo "[Multi] All instances terminated."
    exit 0
}

trap cleanup INT TERM

for dev in $DEVICE_IDS; do
    echo "[-] Launching instance for $dev..."
    
    # Construct args
    ARGS=""
    [ -n "$RESET_MODE" ] && ARGS="$ARGS $RESET_MODE"
    [ -n "$NO_FILTER" ] && ARGS="$ARGS $NO_FILTER"
    [ -n "$TARGET_ID" ] && ARGS="$ARGS --id $TARGET_ID"
    
    # Run in background and collect PID
    ./run_single.sh "$dev" $ARGS &
    PIDS+=($!)
    
    # Slight delay to prevent USB/CPU burst
    sleep 3
done

echo "[-] All devices launched in background. Press Ctrl+C to terminate all."
wait
