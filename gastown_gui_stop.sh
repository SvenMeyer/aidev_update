#!/bin/bash
set -euo pipefail

GASTOWN_GUI_PORT="${GASTOWN_GUI_PORT:-7667}"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
# shellcheck source=./service_helpers.sh
source "${SCRIPT_DIR}/service_helpers.sh"

kill_port_owner "$GASTOWN_GUI_PORT" "Gastown GUI"
