#!/usr/bin/env bash
# Update the OpenCode CLI via its own upgrade command; install it first on a
# fresh machine.
if command -v opencode >/dev/null 2>&1; then
    exec opencode upgrade
fi
echo "opencode not found — installing the latest version…"
exec npm install -g opencode-ai
