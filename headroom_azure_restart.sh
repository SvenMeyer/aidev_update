#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"

"${SCRIPT_DIR}/headroom_azure_stop.sh"
"${SCRIPT_DIR}/headroom_azure_start.sh"
