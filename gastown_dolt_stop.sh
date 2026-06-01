#!/bin/bash
set -euo pipefail

GT_HOME="${GT_HOME:-${HOME}/gt}"
GASTOWN_DOLT_PORT="${GASTOWN_DOLT_PORT:-3307}"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
# shellcheck source=./service_helpers.sh
source "${SCRIPT_DIR}/service_helpers.sh"

export PATH="${HOME}/.local/bin:${PATH}"

if [[ -f "${GT_HOME}/CLAUDE.md" ]] && command -v gt >/dev/null 2>&1; then
    (
        cd "$GT_HOME"
        gt dolt stop 2>/dev/null || true
    )
fi

if [[ -n "$(get_port_owner "$GASTOWN_DOLT_PORT")" ]]; then
    kill_port_owner "$GASTOWN_DOLT_PORT" "Gastown Dolt server"
else
    echo "Nothing listening on port ${GASTOWN_DOLT_PORT}"
fi
