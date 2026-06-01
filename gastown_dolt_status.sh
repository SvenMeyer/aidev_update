#!/bin/bash
set -euo pipefail

GASTOWN_DOLT_PORT="${GASTOWN_DOLT_PORT:-3307}"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
# shellcheck source=./service_helpers.sh
source "${SCRIPT_DIR}/service_helpers.sh"

owner=$(get_port_owner "$GASTOWN_DOLT_PORT")
if [[ -n "$owner" ]]; then
    echo "✓ Gastown Dolt server is running on port ${GASTOWN_DOLT_PORT} (${owner})"
else
    echo "○ Gastown Dolt server is stopped (port ${GASTOWN_DOLT_PORT} is free)"
fi
