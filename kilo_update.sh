#!/bin/bash

retry_command() {
    local max_attempts=2
    local attempt=1

    while [ $attempt -le $max_attempts ]; do
        if "$@"; then
            return 0
        else
            echo "Attempt $attempt failed. Retrying..."
            ((attempt++))
            sleep 2
        fi
    done

    echo "All attempts failed."
    return 1
}

echo "Kilo CLI Update Script"

CURRENT_VERSION=$(kilo --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
if [[ -n "$CURRENT_VERSION" ]]; then
    echo "Installed version   : $CURRENT_VERSION"
else
    echo "Installed version   : not installed"
fi

echo "Fetching latest version information..."
LATEST_VERSION=$(retry_command npm view @kilocode/cli version 2>/dev/null)

if [[ -z "$LATEST_VERSION" ]]; then
    echo "❌ Could not resolve latest @kilocode/cli version"
    exit 1
fi

echo "Latest version      : $LATEST_VERSION"

if [[ "$CURRENT_VERSION" == "$LATEST_VERSION" ]]; then
    echo "Kilo is already up to date!"
    exit 0
fi

echo "Installing @kilocode/cli@$LATEST_VERSION..."
if retry_command npm install -g "@kilocode/cli@$LATEST_VERSION"; then
    echo "Updated version     : $(kilo --version 2>/dev/null || echo 'unknown')"
    echo "✓ Kilo update completed successfully!"
else
    echo "❌ Kilo update failed!"
    exit 1
fi
