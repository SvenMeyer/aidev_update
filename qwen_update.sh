#!/bin/bash
# Qwen Code CLI update: installs the stable release only (npm dist-tag
# "latest"). nightly/preview/dev builds are never selected; an installed
# prerelease is replaced by (downgraded to) the current stable version.

PKG="@qwen-code/qwen-code"

# Basic retry function
retry_command() {
    local max_attempts=2
    local attempt=1

    while [ $attempt -le $max_attempts ]; do
        if "$@"; then
            return 0
        else
            echo "Attempt $attempt failed. Retrying..." >&2
            ((attempt++))
            sleep 2
        fi
    done

    echo "All attempts failed." >&2
    return 1
}

extract_semver() {
    if [[ "$1" =~ ([0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?) ]]; then
        echo "${BASH_REMATCH[1]}"
    fi
}

echo "Qwen Code CLI Auto-Update Script"
echo "Installing latest stable version"

if ! command -v npm >/dev/null 2>&1; then
    echo "❌ 'npm' is required but not installed. Please install npm and try again."
    exit 1
fi

echo "Fetching latest stable version..."
LATEST_VERSION=$(retry_command npm view "$PKG" dist-tags.latest)
if [[ ! "$LATEST_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "❌ Could not determine the latest stable version (got: '${LATEST_VERSION}')"
    exit 1
fi
echo "Latest stable version: $LATEST_VERSION"

if command -v qwen >/dev/null 2>&1; then
    CURRENT_VERSION=$(extract_semver "$(qwen --version 2>/dev/null)")
    echo "Installed version: ${CURRENT_VERSION:-unknown}"

    if [[ "$CURRENT_VERSION" == "$LATEST_VERSION" ]]; then
        echo "Qwen Code is already up to date!"
        echo "-------------------------------------"
        exit 0
    fi
    if [[ "$CURRENT_VERSION" == *-* ]]; then
        echo "Installed version is a prerelease — replacing it with stable $LATEST_VERSION"
    fi
else
    echo "Installed version: not installed"
fi

echo "Installing $PKG@$LATEST_VERSION..."
if retry_command npm install -g "$PKG@$LATEST_VERSION"; then
    echo "Updated version:"
    qwen --version
    echo "✓ Qwen Code update completed successfully!"
else
    echo "❌ Qwen Code update failed!"
    exit 1
fi
