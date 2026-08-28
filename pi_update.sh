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

echo "pi Coding Agent Auto-Update Script"
echo "Installing latest version"

# Get current version
echo "Current version:"
npm ls -g @mariozechner/pi-coding-agent 2>/dev/null | grep pi-coding-agent || echo "Not installed"

# Get latest version
echo "Fetching latest version information..."
LATEST_VERSION=$(retry_command npm view @mariozechner/pi-coding-agent version)
echo "Latest version: $LATEST_VERSION"

# Extract version number from current installation
CURRENT_VERSION=$(npm ls -g @mariozechner/pi-coding-agent 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
if [[ -n "$CURRENT_VERSION" ]]; then
    echo "Installed version number: $CURRENT_VERSION"

    if [[ "$CURRENT_VERSION" == "$LATEST_VERSION" ]]; then
        echo "pi is already up to date!"
        echo "-------------------------------------"
        exit 0
    fi
fi

# Install latest version
echo "Installing @mariozechner/pi-coding-agent@$LATEST_VERSION..."
if retry_command npm install -g "@mariozechner/pi-coding-agent@$LATEST_VERSION"; then
    # Verify installation
    echo "Updated version:"
    npm ls -g @mariozechner/pi-coding-agent 2>/dev/null | grep pi-coding-agent
    echo "✓ pi update completed successfully!"
else
    echo "❌ pi update failed!"
    exit 1
fi
