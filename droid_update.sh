#!/usr/bin/env bash
# Update the DROID CLI via its own update command; install it first on a
# fresh machine using Factory's official installer.
if command -v droid >/dev/null 2>&1; then
    exec droid update
fi
echo "droid not found — installing the latest version…"
exec sh -c "$(curl -fsSL https://app.factory.ai/cli)"
