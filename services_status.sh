#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"

"${SCRIPT_DIR}/headroom_status.sh" || true
"${SCRIPT_DIR}/headroom_azure_status.sh" || true
"${SCRIPT_DIR}/gastown_dashboard_status.sh" || true
"${SCRIPT_DIR}/gastown_gui_status.sh" || true
