#!/usr/bin/env bash
# Update the Kilo CLI via its own upgrade command; install it first on a
# fresh machine.
if command -v kilo >/dev/null 2>&1; then
    exec kilo upgrade
fi
echo "kilo not found — installing the latest version…"
exec npm install -g @kilocode/cli
