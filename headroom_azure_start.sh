#!/bin/bash
# Headroom proxy with --backend litellm-azure on port 8788.
# Runs in parallel to the default Anthropic-backend instance on 8787.
# Reads AZURE_API_KEY / AZURE_API_BASE / AZURE_API_VERSION from the
# environment when starting; the inbound Authorization: Bearer token
# from droid is what headroom actually forwards as the Azure api-key,
# so the api key must also be configured per-model in droid's settings.
set -euo pipefail

HEADROOM_HOST="127.0.0.1"
HEADROOM_PORT=8788
LOG_DIR="${HOME}/.headroom/logs"
LOG_FILE="${LOG_DIR}/proxy_azure.log"
JSONL_LOG="${LOG_DIR}/proxy_azure_messages.jsonl"
HEALTH_URL="http://${HEADROOM_HOST}:${HEADROOM_PORT}/health"
HEALTH_CHECK_ATTEMPTS=12
HEALTH_CHECK_INTERVAL=5

: "${AZURE_API_KEY:?AZURE_API_KEY must be set}"
: "${AZURE_API_BASE:?AZURE_API_BASE must be set}"
: "${AZURE_API_VERSION:?AZURE_API_VERSION must be set}"

# Codex only speaks the OpenAI Responses API (/v1/responses), which the
# litellm-azure backend does not translate — it falls through to api.openai.com.
# Point Headroom's OpenAI/Codex passthrough at the same Azure deployment so that
# /v1/responses reaches Azure. The litellm-azure chat/completions path (used by
# droid) is unaffected. Codex must still send the `api-key` header and the
# `api-version` query param (see the inf-azure-hr Codex profile).
OPENAI_TARGET_API_URL="${AZURE_API_BASE%/}/openai/v1"

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

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
if ! HEADROOM_BIN=$(resolve_headroom_bin); then
    echo "❌ 'headroom' CLI not found. Run ${SCRIPT_DIR}/headroom_update.sh first." >&2
    exit 1
fi

mkdir -p "$LOG_DIR"

# Exit early if the service is already healthy.
response=$(curl -fsSL "$HEALTH_URL" 2>/dev/null || true)
if [[ -n "$response" ]] && \
   python3 -c 'import json,sys; d=json.load(sys.stdin); s=str(d.get("status","")).lower(); r=str(d.get("ready","")).lower(); sys.exit(0 if s=="healthy" or r=="true" else 1)' <<<"$response" 2>/dev/null; then
    echo "✓ Headroom (azure) is already running ($HEALTH_URL)"
    exit 0
fi

# Bail out if something unexpected is already listening on the port.
if lsof -nP -iTCP:"$HEADROOM_PORT" -sTCP:LISTEN >/dev/null 2>&1; then
    echo "❌ Port $HEADROOM_PORT already in use by another process:"
    lsof -nP -iTCP:"$HEADROOM_PORT" -sTCP:LISTEN
    exit 1
fi

echo "Starting headroom proxy (litellm-azure) on $HEADROOM_HOST:$HEADROOM_PORT (log: $LOG_FILE)..."
nohup env \
    AZURE_API_KEY="$AZURE_API_KEY" \
    AZURE_API_BASE="$AZURE_API_BASE" \
    AZURE_API_VERSION="$AZURE_API_VERSION" \
    OPENAI_TARGET_API_URL="$OPENAI_TARGET_API_URL" \
    "$HEADROOM_BIN" proxy \
        --host "$HEADROOM_HOST" \
        --port "$HEADROOM_PORT" \
        --backend litellm-azure \
        --mode token \
        --log-file "$JSONL_LOG" \
        --log-messages \
    > "$LOG_FILE" 2>&1 &
echo "Proxy PID: $!"

attempt=1
while (( attempt <= HEALTH_CHECK_ATTEMPTS )); do
    response=$(curl -fsSL "$HEALTH_URL" 2>/dev/null || true)
    if [[ -n "$response" ]] && \
       python3 -c 'import json,sys; d=json.load(sys.stdin); s=str(d.get("status","")).lower(); r=str(d.get("ready","")).lower(); sys.exit(0 if s=="healthy" or r=="true" else 1)' <<<"$response" 2>/dev/null; then
        echo "✓ Headroom (azure) is healthy ($HEALTH_URL)"
        exit 0
    fi
    (( attempt == HEALTH_CHECK_ATTEMPTS )) && break
    ((attempt++))
    sleep "$HEALTH_CHECK_INTERVAL"
done

echo "❌ Azure proxy did not become healthy within $((HEALTH_CHECK_ATTEMPTS*HEALTH_CHECK_INTERVAL))s. Check $LOG_FILE" >&2
exit 1
