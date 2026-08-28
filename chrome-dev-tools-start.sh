#!/bin/bash
# Launch the Chrome sidecar with an isolated profile for MCP / devtools use.

exec "$HOME/.local/opt/google-chrome-sidecar/opt/google/chrome/google-chrome" \
    --user-data-dir="$HOME/.config/google-chrome-mcp" \
    --no-first-run \
    --no-default-browser-check \
    "$@"
