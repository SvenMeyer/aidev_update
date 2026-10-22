#!/usr/bin/env bash
# Update Claude Code via the official CLI command; install it first on a
# fresh machine with the official native installer (~/.local/bin/claude).
# ~/.local/bin goes on PATH so a native install is found from cron as well.
PATH="$HOME/.local/bin:$PATH"
if command -v claude >/dev/null 2>&1; then
    exec claude update
fi
echo "claude not found — installing the latest version…"
curl -fsSL https://claude.ai/install.sh | bash
