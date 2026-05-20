#!/bin/bash
# Stop the headroom litellm-azure instance running on port 8788.
set -euo pipefail

HEADROOM_PORT=8788

get_port_owner() {
    lsof -nP -iTCP:"${1}" -sTCP:LISTEN 2>/dev/null | awk 'NR>1 {print $1, $2; exit}' || true
}

PORT_OWNER=$(get_port_owner "$HEADROOM_PORT")
if [[ -z "$PORT_OWNER" ]]; then
    echo "Nothing listening on port $HEADROOM_PORT"
    exit 0
fi

OWNER_NAME=$(echo "$PORT_OWNER" | awk '{print $1}')
OWNER_PID=$(echo "$PORT_OWNER" | awk '{print $2}')
echo "Killing $OWNER_NAME (PID $OWNER_PID) on port $HEADROOM_PORT..."
kill "$OWNER_PID" 2>/dev/null || true
sleep 1
if kill -0 "$OWNER_PID" 2>/dev/null; then
    kill -9 "$OWNER_PID" 2>/dev/null || true
fi

sleep 1
if [[ -n "$(get_port_owner "$HEADROOM_PORT")" ]]; then
    echo "❌ Port $HEADROOM_PORT still occupied." >&2
    exit 1
fi

echo "✓ Headroom (azure) stopped, port $HEADROOM_PORT is free"
