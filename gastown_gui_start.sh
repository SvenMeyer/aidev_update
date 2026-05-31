#!/bin/bash
set -euo pipefail

GT_ROOT="${GT_ROOT:-${HOME}/gt}"
GASTOWN_GUI_HOST="${GASTOWN_GUI_HOST:-127.0.0.1}"
GASTOWN_GUI_PORT="${GASTOWN_GUI_PORT:-7667}"
LOG_DIR="${HOME}/.gastown-gui/logs"
LOG_FILE="${LOG_DIR}/server.log"
URL="http://${GASTOWN_GUI_HOST}:${GASTOWN_GUI_PORT}"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
# shellcheck source=./service_helpers.sh
source "${SCRIPT_DIR}/service_helpers.sh"

if ! command -v gastown-gui >/dev/null 2>&1; then
    echo "❌ 'gastown-gui' not found. Run ${SCRIPT_DIR}/gastown_gui_update.sh first." >&2
    exit 1
fi

if [[ ! -f "${GT_ROOT}/CLAUDE.md" ]]; then
    echo "❌ Gastown HQ not found at ${GT_ROOT}. Run ${SCRIPT_DIR}/gastown_update.sh first." >&2
    exit 1
fi

if print_http_status "Gastown GUI" "$GASTOWN_GUI_PORT" "$URL"; then
    exit 0
fi

if [[ -n "$(get_port_owner "$GASTOWN_GUI_PORT")" ]]; then
    echo "❌ Port ${GASTOWN_GUI_PORT} is already in use by another process." >&2
    exit 1
fi

mkdir -p "$LOG_DIR"

echo "Starting Gastown GUI at ${URL}..."
nohup env GT_ROOT="$GT_ROOT" HOST="$GASTOWN_GUI_HOST" GASTOWN_PORT="$GASTOWN_GUI_PORT" \
    gastown-gui start --host "$GASTOWN_GUI_HOST" --port "$GASTOWN_GUI_PORT" \
    > "$LOG_FILE" 2>&1 &
echo "Gastown GUI PID: $!"

if wait_for_http_ok "$URL"; then
    echo "✓ Gastown GUI is running (${URL})"
else
    echo "❌ Gastown GUI did not become ready. Check ${LOG_FILE}" >&2
    exit 1
fi
