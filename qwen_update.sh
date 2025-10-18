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

echo "Qwen Code CLI Auto-Update Script"
echo "Installing latest version (including nightly builds)"

# Check dependencies
if ! command -v jq >/dev/null 2>&1; then
    echo "❌ 'jq' is required but not installed. Please install jq and try again."
    echo "   On Ubuntu/Debian: sudo apt-get install jq"
    echo "   On macOS: brew install jq"
    exit 1
fi

# Get current version
echo "Current version:"
qwen --version 2>/dev/null || echo "Not installed"

# Get all versions with publication dates and select the most recently published
echo "Fetching latest version information..."
LATEST_VERSION=$(retry_command npm view @qwen-code/qwen-code time --json | jq -r 'to_entries[] | select(.key != "created" and .key != "modified") | select(.key | startswith("0.")) | .key' | tail -1)
echo "Latest version: $LATEST_VERSION"

# Extract version number from current installation
if command -v qwen &> /dev/null; then
    CURRENT_VERSION=$(qwen --version 2>/dev/null)
    echo "Installed version: $CURRENT_VERSION"

    if [[ "$CURRENT_VERSION" == "$LATEST_VERSION" ]]; then
        echo "Qwen Code is already up to date!"
        echo "-------------------------------------"
        exit 0
    fi
fi

# Install latest version
echo "Installing @qwen-code/qwen-code@$LATEST_VERSION..."
if retry_command npm install -g "@qwen-code/qwen-code@$LATEST_VERSION"; then
    # Verify installation
    echo "Updated version:"
    qwen --version
    echo "✓ Qwen Code update completed successfully!"
else
    echo "❌ Qwen Code update failed!"
    exit 1
fi