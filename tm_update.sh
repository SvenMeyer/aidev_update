#!/bin/bash

# Basic retry helper (kept consistent with other update scripts)
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

echo "Taskmaster Auto-Update"
echo "Preference: use RC channel when available"

# Check dependency
if ! command -v npm >/dev/null 2>&1; then
    echo "❌ 'npm' is required but not installed. Please install npm and try again."
    exit 1
fi

# Show current version
CURRENT_VERSION_RAW=$(task-master --version 2>/dev/null || true)
echo "Current version: ${CURRENT_VERSION_RAW:-Not installed}"

# Extract a semver from current version output (e.g. 0.29.0 or 0.29.0-rc.3)
CURRENT_VERSION=$(echo "$CURRENT_VERSION_RAW" | grep -oE '([0-9]+\.){2}[0-9]+(-[0-9A-Za-z\.]+)?' | head -1 || true)

echo "Fetching version info (stable and rc)..."
STABLE_VERSION=$(retry_command npm view task-master-ai version 2>/dev/null || true)
RC_VERSION=$(retry_command npm view task-master-ai@rc version 2>/dev/null || true)

# Normalize empty values
STABLE_VERSION=${STABLE_VERSION:-}
RC_VERSION=${RC_VERSION:-}

if [ -n "$RC_VERSION" ]; then
    DESIRED_CHANNEL="rc"
    DESIRED_VERSION="$RC_VERSION"
else
    DESIRED_CHANNEL="latest"
    DESIRED_VERSION="$STABLE_VERSION"
fi

echo "Latest stable: ${STABLE_VERSION:-unknown}"
echo "Latest rc: ${RC_VERSION:-none}"
echo "Target: $DESIRED_CHANNEL ($DESIRED_VERSION)"

# If we can determine the current version and it matches the desired one, skip
if [ -n "$CURRENT_VERSION" ] && [ -n "$DESIRED_VERSION" ] && [ "$CURRENT_VERSION" = "$DESIRED_VERSION" ]; then
    echo "✓ Taskmaster already up-to-date ($CURRENT_VERSION). Skipping."
    exit 0
fi

# Install using the appropriate channel tag so we keep tracking RC when available
install_with_fallback() {
    local spec="$1" # e.g., task-master-ai@rc or task-master-ai@latest
    if retry_command npm install -g "$spec"; then
        return 0
    fi
    echo "Primary install failed. Retrying with --legacy-peer-deps due to potential peer dependency conflicts (e.g., zod v3→v4)." >&2
    if retry_command npm install -g "$spec" --legacy-peer-deps; then
        return 0
    fi
    return 1
}

if [ "$DESIRED_CHANNEL" = "rc" ]; then
    echo "Installing task-master-ai@rc ($DESIRED_VERSION) ..."
    if ! install_with_fallback task-master-ai@rc; then
        echo "❌ Taskmaster RC install failed"
        exit 1
    fi
else
    echo "Installing task-master-ai@latest ($DESIRED_VERSION) ..."
    if ! install_with_fallback task-master-ai@latest; then
        echo "❌ Taskmaster install failed"
        exit 1
    fi
fi

# Verify installation
echo "Updated version:"
if ! command -v task-master >/dev/null 2>&1; then
    echo "Installation finished, but 'task-master' is not on PATH." >&2
    echo "npm global prefix: $(npm config get prefix)" >&2
    echo "Ensure your PATH includes: $(npm bin -g)" >&2
else
    task-master --version 2>/dev/null || true
fi
echo "✓ Taskmaster update completed"
