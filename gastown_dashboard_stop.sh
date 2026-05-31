#!/bin/bash
set -euo pipefail

GASTOWN_DASHBOARD_PORT="${GASTOWN_DASHBOARD_PORT:-8080}"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
# shellcheck source=./service_helpers.sh
source "${SCRIPT_DIR}/service_helpers.sh"

kill_port_owner "$GASTOWN_DASHBOARD_PORT" "Gastown dashboard"
