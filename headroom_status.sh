#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
# shellcheck source=./service_helpers.sh
source "${SCRIPT_DIR}/service_helpers.sh"

print_http_status "Headroom" 8787 "http://127.0.0.1:8787/health"
