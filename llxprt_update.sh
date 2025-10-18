#!/bin/bash

# Basic retry function
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

echo "LLxprt Code CLI Auto-Update Script"
echo "Installing latest version"

# Get current version
echo "Current version:"
llxprt --version 2>/dev/null || echo "Not installed"

# Get latest version
echo "Fetching latest version information..."
LATEST_VERSION=$(retry_command npm view @vybestack/llxprt-code version)
echo "Latest version: $LATEST_VERSION"

# Extract version number from current installation
if command -v llxprt &> /dev/null; then
    CURRENT_VERSION=$(llxprt --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    echo "Installed version number: $CURRENT_VERSION"

    if [[ "$CURRENT_VERSION" == "$LATEST_VERSION" ]]; then
        echo "LLxprt Code is already up to date!"
        echo "-------------------------------------"
        exit 0
    fi
fi

# Install latest version
echo "Installing @vybestack/llxprt-code@$LATEST_VERSION..."
if retry_command npm install -g "@vybestack/llxprt-code@$LATEST_VERSION"; then
    # Verify installation
    echo "Updated version:"
    llxprt --version
    echo "✓ LLxprt Code update completed successfully!"
else
    echo "❌ LLxprt Code update failed!"
    exit 1
fi