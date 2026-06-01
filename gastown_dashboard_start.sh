#!/bin/bash
set -euo pipefail

GT_HOME="${GT_HOME:-${HOME}/gt}"
GASTOWN_DASHBOARD_HOST="${GASTOWN_DASHBOARD_HOST:-127.0.0.1}"
GASTOWN_DASHBOARD_PORT="${GASTOWN_DASHBOARD_PORT:-8080}"
LOG_DIR="${GT_HOME}/logs"
LOG_FILE="${LOG_DIR}/gastown_dashboard.log"
URL="http://${GASTOWN_DASHBOARD_HOST}:${GASTOWN_DASHBOARD_PORT}"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
# shellcheck source=./service_helpers.sh
source "${SCRIPT_DIR}/service_helpers.sh"

export PATH="${HOME}/.local/bin:${PATH}"

if ! command -v gt >/dev/null 2>&1; then
    echo "❌ 'gt' CLI not found. Run ${SCRIPT_DIR}/gastown_update.sh first." >&2
    exit 1
fi

if [[ ! -f "${GT_HOME}/CLAUDE.md" ]]; then
    echo "❌ Gastown HQ not found at ${GT_HOME}. Run ${SCRIPT_DIR}/gastown_update.sh first." >&2
    exit 1
fi

"${SCRIPT_DIR}/gastown_dolt_start.sh"

if print_http_status "Gastown dashboard" "$GASTOWN_DASHBOARD_PORT" "$URL"; then
    exit 0
fi

if [[ -n "$(get_port_owner "$GASTOWN_DASHBOARD_PORT")" ]]; then
    echo "❌ Port ${GASTOWN_DASHBOARD_PORT} is already in use by another process." >&2
    exit 1
fi

mkdir -p "$LOG_DIR"

echo "Starting Gastown dashboard at ${URL}..."
nohup env GT_TOWN_ROOT="$GT_HOME" gt dashboard --bind "$GASTOWN_DASHBOARD_HOST" --port "$GASTOWN_DASHBOARD_PORT" \
    > "$LOG_FILE" 2>&1 &
echo "Dashboard PID: $!"

if wait_for_http_ok "$URL"; then
    echo "✓ Gastown dashboard is running (${URL})"
else
    echo "❌ Gastown dashboard did not become ready. Check ${LOG_FILE}" >&2
    exit 1
fi
