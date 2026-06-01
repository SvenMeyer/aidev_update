#!/bin/bash
set -euo pipefail

GT_HOME="${GT_HOME:-${HOME}/gt}"
GASTOWN_DOLT_PORT="${GASTOWN_DOLT_PORT:-3307}"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
# shellcheck source=./service_helpers.sh
source "${SCRIPT_DIR}/service_helpers.sh"

export PATH="${HOME}/.local/bin:${PATH}"

if [[ ! -f "${GT_HOME}/CLAUDE.md" ]]; then
    echo "❌ Gastown HQ not found at ${GT_HOME}. Run ${SCRIPT_DIR}/gastown_update.sh first." >&2
    exit 1
fi

if [[ -n "$(get_port_owner "$GASTOWN_DOLT_PORT")" ]]; then
    echo "✓ Gastown Dolt server is already running on port ${GASTOWN_DOLT_PORT}"
    exit 0
fi

(
    cd "$GT_HOME"
    gt dolt start
)

if [[ -n "$(get_port_owner "$GASTOWN_DOLT_PORT")" ]]; then
    echo "✓ Gastown Dolt server is running on port ${GASTOWN_DOLT_PORT}"
else
    echo "❌ Gastown Dolt server did not start on port ${GASTOWN_DOLT_PORT}." >&2
    exit 1
fi
