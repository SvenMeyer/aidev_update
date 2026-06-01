#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"

"${SCRIPT_DIR}/gastown_dolt_stop.sh"
"${SCRIPT_DIR}/gastown_dolt_start.sh"
