#!/bin/bash
set -euo pipefail

GASTOWN_DASHBOARD_HOST="${GASTOWN_DASHBOARD_HOST:-127.0.0.1}"
GASTOWN_DASHBOARD_PORT="${GASTOWN_DASHBOARD_PORT:-8080}"
URL="http://${GASTOWN_DASHBOARD_HOST}:${GASTOWN_DASHBOARD_PORT}"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
# shellcheck source=./service_helpers.sh
source "${SCRIPT_DIR}/service_helpers.sh"

print_http_status "Gastown dashboard" "$GASTOWN_DASHBOARD_PORT" "$URL"
