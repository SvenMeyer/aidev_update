#!/bin/bash
set -euo pipefail

HEADROOM_PORT=8787
DEPLOY_ROOT="${HOME}/.headroom/deploy"

resolve_headroom_bin() {
    local candidate=""
    for candidate in \
        "${HEADROOM_BIN:-}" \
        "$(command -v headroom 2>/dev/null || true)" \
        "${HOME}/.local/bin/headroom" \
        "${PIPX_HOME:-${HOME}/.local/share/pipx}/venvs/headroom-ai/bin/headroom"; do
        [[ -n "$candidate" && -x "$candidate" ]] || continue
        printf '%s\n' "$candidate"
        return 0
    done
    return 1
}

find_profiles_on_port() {
    local port="$1"
    if [[ -d "$DEPLOY_ROOT" ]]; then
        for manifest in "$DEPLOY_ROOT"/*/manifest.json; do
            [[ -f "$manifest" ]] || continue
            python3 - "$manifest" "$port" <<'PY' 2>/dev/null || true
import json, sys
manifest_path, target_port = sys.argv[1], sys.argv[2]
with open(manifest_path) as f:
    data = json.load(f)
if str(data.get("port", "")) == target_port:
    print(f"{data.get('updated_at', '')}\t{data.get('profile', '')}\t{data.get('health_url', '')}")
PY
        done
    fi
}

get_port_owner() {
    lsof -nP -iTCP:"${1}" -sTCP:LISTEN 2>/dev/null | awk 'NR>1 {print $1, $2; exit}' || true
}

HEADROOM_BIN=$(resolve_headroom_bin || true)

# Stop manifest-tracked profiles
while IFS=$'\t' read -r updated_at profile health_url; do
    [[ -n "$profile" ]] || continue
    if [[ -n "$HEADROOM_BIN" ]]; then
        echo "Stopping manifest profile '$profile'..."
        "$HEADROOM_BIN" install stop --profile "$profile" 2>/dev/null || true
    else
        echo "⚠ 'headroom' CLI not found; skipping manifest stop for '$profile'." >&2
    fi
done < <(find_profiles_on_port "$HEADROOM_PORT")

# Kill any remaining process on the port
PORT_OWNER=$(get_port_owner "$HEADROOM_PORT")
if [[ -n "$PORT_OWNER" ]]; then
    OWNER_NAME=$(echo "$PORT_OWNER" | awk '{print $1}')
    OWNER_PID=$(echo "$PORT_OWNER" | awk '{print $2}')
    echo "Killing $OWNER_NAME (PID $OWNER_PID) on port $HEADROOM_PORT..."
    kill "$OWNER_PID" 2>/dev/null || true
    sleep 1
    if kill -0 "$OWNER_PID" 2>/dev/null; then
        kill -9 "$OWNER_PID" 2>/dev/null || true
    fi
fi

sleep 1
if [[ -n "$(get_port_owner "$HEADROOM_PORT")" ]]; then
    echo "❌ Port $HEADROOM_PORT still occupied." >&2
    exit 1
fi

echo "✓ Headroom stopped, port $HEADROOM_PORT is free"
