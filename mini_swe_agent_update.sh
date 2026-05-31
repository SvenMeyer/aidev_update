#!/bin/bash

REPO_URL="git+https://github.com/SWE-agent/mini-swe-agent.git"

echo "mini-swe-agent Update Script"

CURRENT_VERSION=$(pipx list 2>/dev/null | awk '/package mini-swe-agent / {print $3}' | tr -d ',')
if [[ -n "$CURRENT_VERSION" ]]; then
    echo "Installed version   : $CURRENT_VERSION"
else
    echo "Installed version   : not installed"
fi

echo "Installing latest version from GitHub..."
if ! pipx install --force "$REPO_URL"; then
    echo "❌ mini-swe-agent update failed!"
    exit 1
fi

UPDATED_VERSION=$(pipx list 2>/dev/null | awk '/package mini-swe-agent / {print $3}' | tr -d ',')
if [[ -n "$UPDATED_VERSION" ]]; then
    echo "Updated version     : $UPDATED_VERSION"
fi

if mini --help >/dev/null 2>&1; then
    echo "✓ mini-swe-agent update completed successfully!"
else
    echo "❌ mini command verification failed!"
    exit 1
fi
