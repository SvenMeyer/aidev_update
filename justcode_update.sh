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

echo "JustCode CLI Auto-Update Script"
echo "Installing latest version"

# Get current version
echo "Current version:"
coder --version 2>/dev/null || echo "Not installed"

# Get latest version
echo "Fetching latest version information..."
LATEST_VERSION=$(retry_command npm view @just-every/code version)
echo "Latest version: $LATEST_VERSION"

# Extract version number from current installation
if command -v coder &> /dev/null; then
    CURRENT_VERSION=$(coder --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    echo "Installed version number: $CURRENT_VERSION"

    if [[ "$CURRENT_VERSION" == "$LATEST_VERSION" ]]; then
        echo "JustCode is already up to date!"
        echo "-------------------------------------"
        exit 0
    fi
fi

# Install latest version
echo "Installing @just-every/code@$LATEST_VERSION..."
if retry_command npm install -g "@just-every/code@$LATEST_VERSION"; then
    # Verify installation
    echo "Updated version:"
    coder --version
    echo "✓ JustCode update completed successfully!"
else
    echo "❌ JustCode update failed!"
    exit 1
fi