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

echo "OpenAI Codex CLI Auto-Update Script"
echo "Installing latest version (including preview/beta/alpha)"

# Check dependencies
if ! command -v jq >/dev/null 2>&1; then
    echo "❌ 'jq' is required but not installed. Please install jq and try again."
    echo "   On Ubuntu/Debian: sudo apt-get install jq"
    echo "   On macOS: brew install jq"
    exit 1
fi

# Get current version
echo "Current version:"
codex --version 2>/dev/null || echo "Not installed"

# Get all versions and select the latest one (including preview/beta/alpha)
echo "Fetching latest version information..."
LATEST_VERSION=$(retry_command npm view @openai/codex versions --json | jq -r '.[-1]')
echo "Latest version: $LATEST_VERSION"

# Extract version number from current installation
if command -v codex &> /dev/null; then
    CURRENT_VERSION=$(codex --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9]+(\.[0-9]+)?)?' | head -1)
    echo "Installed version number: $CURRENT_VERSION"

    if [[ "$CURRENT_VERSION" == "$LATEST_VERSION" ]]; then
        echo "OpenAI Codex is already up to date!"
        echo "-------------------------------------"
        exit 0
    fi
fi

# Install latest version
echo "Installing @openai/codex@$LATEST_VERSION"
if retry_command npm install -g "@openai/codex@$LATEST_VERSION"; then
    # Verify installation
    echo "Updated version:"
    codex --version
    echo "✓ OpenAI Codex update completed successfully!"
else
    echo "❌ OpenAI Codex update failed!"
    exit 1
fi
