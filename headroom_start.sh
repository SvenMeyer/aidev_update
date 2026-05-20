#!/bin/bash
set -euo pipefail

HEADROOM_HOST="127.0.0.1"
HEADROOM_PORT=8787
DEPLOY_ROOT="${HOME}/.headroom/deploy"
LOG_DIR="${HOME}/.headroom/logs"
LOG_FILE="${LOG_DIR}/proxy.log"
JSONL_LOG="${LOG_DIR}/proxy_messages.jsonl"
HEALTH_CHECK_ATTEMPTS=12
HEALTH_CHECK_INTERVAL=5

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

find_latest_profile_on_port() {
    local port="$1"
    local latest_profile="" latest_health_url="" latest_updated_at=""
    if [[ -d "$DEPLOY_ROOT" ]]; then
        for manifest in "$DEPLOY_ROOT"/*/manifest.json; do
            [[ -f "$manifest" ]] || continue
            while IFS=$'\t' read -r updated_at profile health_url; do
                [[ -n "$profile" ]] || continue
                if [[ -z "$latest_updated_at" || "$updated_at" > "$latest_updated_at" ]]; then
                    latest_profile="$profile"
                    latest_health_url="$health_url"
                    latest_updated_at="$updated_at"
                fi
            done < <(python3 - "$manifest" "$port" <<'PY' 2>/dev/null || true
import json, sys
manifest_path, target_port = sys.argv[1], sys.argv[2]
with open(manifest_path) as f:
    data = json.load(f)
if str(data.get("port", "")) == target_port:
    print(f"{data.get('updated_at', '')}\t{data.get('profile', '')}\t{data.get('health_url', '')}")
PY
            )
        done
    fi
    echo "$latest_profile"$'\t'"$latest_health_url"
}

is_healthy_response() {
    python3 -c 'import json,sys; d=json.load(sys.stdin); s=str(d.get("status","")).lower(); r=str(d.get("ready","")).lower(); sys.exit(0 if s=="healthy" or r=="true" else 1)' 2>/dev/null
}

wait_for_health() {
    local attempt=1
    local url response
    local -a urls=("$@")
    while (( attempt <= HEALTH_CHECK_ATTEMPTS )); do
        for url in "${urls[@]}"; do
            [[ -n "$url" ]] || continue
            response=$(curl -fsSL "$url" 2>/dev/null || true)
            if [[ -n "$response" ]] && is_healthy_response <<<"$response"; then
                echo "$url"
                return 0
            fi
        done
        (( attempt == HEALTH_CHECK_ATTEMPTS )) && break
        ((attempt++))
        sleep "$HEALTH_CHECK_INTERVAL"
    done
    return 1
}

mkdir -p "$LOG_DIR"

IFS=$'\t' read -r PRIMARY_PROFILE PRIMARY_HEALTH_URL < <(find_latest_profile_on_port "$HEADROOM_PORT")

if ! HEADROOM_BIN=$(resolve_headroom_bin); then
    echo "❌ 'headroom' CLI not found. Run ./headroom_update.sh first." >&2
    exit 1
fi

if [[ -n "$PRIMARY_PROFILE" ]]; then
    echo "Starting manifest profile '$PRIMARY_PROFILE'..."
    "$HEADROOM_BIN" install start --profile "$PRIMARY_PROFILE"
else
    echo "Starting headroom proxy (log: $LOG_FILE)..."
    nohup "$HEADROOM_BIN" proxy \
        --host "$HEADROOM_HOST" \
        --port "$HEADROOM_PORT" \
        --mode token \
        --log-file "$JSONL_LOG" \
        --log-messages \
        > "$LOG_FILE" 2>&1 &
    echo "Proxy PID: $!"
fi

echo "Waiting for proxy to be healthy..."
HEALTH_URLS=(
    "$PRIMARY_HEALTH_URL"
    "http://${HEADROOM_HOST}:${HEADROOM_PORT}/health"
    "http://localhost:${HEADROOM_PORT}/health"
)

if HEALTH_URL=$(wait_for_health "${HEALTH_URLS[@]}"); then
    echo "✓ Headroom is healthy ($HEALTH_URL)"
else
    echo "❌ Proxy did not become healthy within 60s. Check $LOG_FILE" >&2
    exit 1
fi
