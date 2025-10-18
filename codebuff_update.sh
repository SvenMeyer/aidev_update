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

echo "Codebuff CLI Auto-Update Script"
echo "Installing latest version"

# Get current version
echo "Current version:"
codebuff --version 2>/dev/null || echo "Not installed"

# Get latest version
echo "Fetching latest version information..."
LATEST_VERSION=$(retry_command npm view codebuff version)
echo "Latest version: $LATEST_VERSION"

# Extract version number from current installation
if command -v codebuff &> /dev/null; then
    CURRENT_VERSION=$(codebuff --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    echo "Installed version number: $CURRENT_VERSION"

    if [[ "$CURRENT_VERSION" == "$LATEST_VERSION" ]]; then
        echo "Codebuff is already up to date!"
        echo "-------------------------------------"
        exit 0
    fi
fi

# Install latest version
echo "Installing codebuff@$LATEST_VERSION..."
if retry_command npm install -g "codebuff@$LATEST_VERSION"; then
    # Verify installation
    echo "Updated version:"
    codebuff --version
    echo "✓ Codebuff update completed successfully!"
else
    echo "❌ Codebuff update failed!"
    exit 1
fi