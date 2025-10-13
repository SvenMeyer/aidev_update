#!/bin/bash

# Basic retry helper
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

echo "Claude Code Router Auto-Update"
echo "Preference: use RC channel when available"

# Dependency check
if ! command -v npm >/dev/null 2>&1; then
    echo "❌ 'npm' is required but not installed. Please install npm and try again."
    exit 1
fi

# Helper to try version flags
get_ccr_version_output() {
    local out=""
    if command -v ccr >/dev/null 2>&1; then
        out=$(ccr -v 2>/dev/null || true)
        if [ -z "$out" ]; then out=$(ccr --version 2>/dev/null || true); fi
        if [ -z "$out" ]; then out=$(ccr version 2>/dev/null || true); fi
    fi
    echo "$out"
}

extract_semver() {
    echo "$1" | grep -oE '([0-9]+\.){2}[0-9]+(-[0-9A-Za-z\.]+)?' | head -1 || true
}

# Current version
CURRENT_RAW=$(get_ccr_version_output)
if [ -z "$CURRENT_RAW" ]; then
    CURRENT_FROM_NPM=$(npm ls -g @musistudio/claude-code-router --depth=0 2>/dev/null | grep -oE '@musistudio/claude-code-router@[^[:space:]]+' | sed 's/@musistudio\/claude-code-router@//')
    if [ -n "$CURRENT_FROM_NPM" ]; then
        CURRENT_RAW="@musistudio/claude-code-router $CURRENT_FROM_NPM"
    fi
fi

echo "Current version: ${CURRENT_RAW:-Not installed}"
CURRENT_VER=$(extract_semver "$CURRENT_RAW")

echo "Fetching version info (stable and rc)..."
STABLE_VERSION=$(retry_command npm view @musistudio/claude-code-router version 2>/dev/null || true)
RC_VERSION=$(retry_command npm view @musistudio/claude-code-router@rc version 2>/dev/null || true)

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

# Skip if already at desired version
if [ -n "$CURRENT_VER" ] && [ -n "$DESIRED_VERSION" ] && [ "$CURRENT_VER" = "$DESIRED_VERSION" ]; then
    echo "✓ Claude Code Router already up-to-date ($CURRENT_VER). Skipping."
    exit 0
fi

install_with_fallback() {
    local spec="$1" # @musistudio/claude-code-router@rc or @latest
    if retry_command npm install -g "$spec"; then
        return 0
    fi
    echo "Primary install failed. Retrying with --legacy-peer-deps due to potential peer dependency conflicts." >&2
    if retry_command npm install -g "$spec" --legacy-peer-deps; then
        return 0
    fi
    return 1
}

if [ "$DESIRED_CHANNEL" = "rc" ]; then
    echo "Installing @musistudio/claude-code-router@rc ($DESIRED_VERSION) ..."
    if ! install_with_fallback @musistudio/claude-code-router@rc; then
        echo "❌ Claude Code Router RC install failed"
        exit 1
    fi
else
    echo "Installing @musistudio/claude-code-router@latest ($DESIRED_VERSION) ..."
    if ! install_with_fallback @musistudio/claude-code-router@latest; then
        echo "❌ Claude Code Router install failed"
        exit 1
    fi
fi

# Verify
UPDATED_RAW=$(get_ccr_version_output)
if ! command -v ccr >/dev/null 2>&1; then
    echo "Installation finished, but 'ccr' is not on PATH." >&2
    echo "npm global prefix: $(npm config get prefix)" >&2
    echo "Ensure your PATH includes: $(npm bin -g)" >&2
fi
echo "Updated version: ${UPDATED_RAW:-unknown}"
echo "✓ Claude Code Router update completed"

