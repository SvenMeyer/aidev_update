#!/bin/bash

echo "Repowise Update Script"

if ! command -v uv >/dev/null 2>&1; then
    echo "❌ uv not found, cannot update repowise"
    exit 1
fi

CURRENT_VERSION=$(repowise --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
if [[ -n "$CURRENT_VERSION" ]]; then
    echo "Installed version   : $CURRENT_VERSION"
else
    echo "Installed version   : not installed"
fi

echo "Updating repowise via uv tool..."
if uv tool upgrade repowise; then
    echo "Updated version     : $(repowise --version 2>/dev/null || echo 'unknown')"
    echo "✓ Repowise update completed successfully!"
else
    echo "❌ Repowise update failed!"
    exit 1
fi
