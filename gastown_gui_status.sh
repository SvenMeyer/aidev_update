#!/bin/bash
set -euo pipefail

GASTOWN_GUI_HOST="${GASTOWN_GUI_HOST:-127.0.0.1}"
GASTOWN_GUI_PORT="${GASTOWN_GUI_PORT:-7667}"
URL="http://${GASTOWN_GUI_HOST}:${GASTOWN_GUI_PORT}"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
# shellcheck source=./service_helpers.sh
source "${SCRIPT_DIR}/service_helpers.sh"

print_http_status "Gastown GUI" "$GASTOWN_GUI_PORT" "$URL"
