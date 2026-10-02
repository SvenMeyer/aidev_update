#!/usr/bin/env bash
# Update Claude Code via the official CLI command; install it first on a
# fresh machine.
if command -v claude >/dev/null 2>&1; then
    exec claude update
fi
echo "claude not found — installing the latest version…"
exec npm install -g @anthropic-ai/claude-code
