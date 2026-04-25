#!/usr/bin/env bash
set -euo pipefail

# https://github.com/entireio/cli

if command -v entire >/dev/null 2>&1; then
  entire --version
else
  echo "entire not currently installed"
fi

tmp_script="$(mktemp)"
trap 'rm -f "$tmp_script"' EXIT

curl -fsSL https://entire.io/install.sh -o "$tmp_script"
bash "$tmp_script"

entire --version
