#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"

"${SCRIPT_DIR}/headroom_start.sh"
"${SCRIPT_DIR}/headroom_azure_start.sh"
"${SCRIPT_DIR}/gastown_dashboard_start.sh"
"${SCRIPT_DIR}/gastown_gui_start.sh"
