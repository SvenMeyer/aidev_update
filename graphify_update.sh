#!/bin/bash
set -euo pipefail

# Install or update the official Graphify CLI on Manjaro Linux.
# https://github.com/Graphify-Labs/graphify
# Usage: bash graphify_update.sh
# Prerequisite: uv (on Manjaro: sudo pacman -S uv).
# The official PyPI package is graphifyy (double-y); the CLI is graphify.

echo "Graphify Install / Update"

if ! command -v uv >/dev/null 2>&1; then
    echo "Error: uv is required. Install it with: sudo pacman -S uv" >&2
    exit 1
fi

if command -v graphify >/dev/null 2>&1; then
    printf 'Installed version: '
    graphify --version
else
    echo "Installed version: not installed"
fi

# Handles both a first install and an existing uv-managed installation.
# Refresh the index so a recently published stable release is discovered.
echo "Installing the latest stable graphifyy package via uv..."
uv tool install --upgrade --refresh graphifyy

# Resolve uv's own binary directory, including when it is not yet on PATH.
GRAPHIFY_BIN="$(uv tool dir --bin)/graphify"
if [[ ! -x "$GRAPHIFY_BIN" ]]; then
    echo "Error: graphify executable missing after installation: $GRAPHIFY_BIN" >&2
    exit 1
fi

printf 'Updated version: '
"$GRAPHIFY_BIN" --version
echo "Graphify installation / update completed successfully."
