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

echo "Amp Code Auto-Update"
echo "Preference: use RC channel when available"

# Dependency check
if ! command -v npm >/dev/null 2>&1; then
    echo "❌ 'npm' is required but not installed. Please install npm and try again."
    exit 1
fi

# Helper to try multiple version flags
get_amp_version_output() {
    local out=""
    if command -v amp >/dev/null 2>&1; then
        out=$(amp --version 2>/dev/null || true)
        if [ -z "$out" ]; then out=$(amp version 2>/dev/null || true); fi
        if [ -z "$out" ]; then out=$(amp -v 2>/dev/null || true); fi
        if [ -z "$out" ]; then out=$(amp -V 2>/dev/null || true); fi
    fi
    echo "$out"
}

extract_semver() {
    echo "$1" | grep -oE '([0-9]+\.){2}[0-9]+(-[0-9A-Za-z\.]+)?' | head -1 || true
}

base_triple() {
    # Returns X.Y.Z (first three numeric groups) from a version-like string
    echo "$1" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true
}

# Current version (best effort)
CURRENT_RAW=$(get_amp_version_output)
if [ -z "$CURRENT_RAW" ]; then
    # Fallback: check npm global install tree
    CURRENT_FROM_NPM=$(npm ls -g @sourcegraph/amp --depth=0 2>/dev/null | grep -oE '@sourcegraph/amp@[^[:space:]]+' | sed 's/@sourcegraph\/amp@//')
    if [ -n "$CURRENT_FROM_NPM" ]; then
        CURRENT_RAW="@sourcegraph/amp $CURRENT_FROM_NPM"
    fi
fi

echo "Current version: ${CURRENT_RAW:-Not installed}"
CURRENT_VER=$(extract_semver "$CURRENT_RAW")

echo "Fetching version info (stable and rc)..."
STABLE_VERSION=$(retry_command npm view @sourcegraph/amp version 2>/dev/null || true)
RC_VERSION=$(retry_command npm view @sourcegraph/amp@rc version 2>/dev/null || true)

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

# Skip logic simplified to base X.Y.Z for Amp
if [ -n "$DESIRED_VERSION" ]; then
    if [ "$DESIRED_CHANNEL" = "rc" ]; then
        # If targeting RC, only skip when exact version matches (ensure we upgrade to RC otherwise)
        if [ -n "$CURRENT_VER" ] && [ "$CURRENT_VER" = "$DESIRED_VERSION" ]; then
            echo "✓ Amp Code already up-to-date ($CURRENT_VER). Skipping."
            exit 0
        fi
    else
        # For latest/stable, compare only X.Y.Z to avoid noise from commit/date suffixes
        CURRENT_BASE=$(base_triple "$CURRENT_VER")
        DESIRED_BASE=$(base_triple "$DESIRED_VERSION")
        if [ -n "$CURRENT_BASE" ] && [ -n "$DESIRED_BASE" ] && [ "$CURRENT_BASE" = "$DESIRED_BASE" ]; then
            echo "✓ Amp Code base version matches ($CURRENT_BASE). Skipping."
            exit 0
        fi
    fi
fi

# Install using channel tag so we keep tracking the channel
install_with_fallback() {
    local spec="$1" # @sourcegraph/amp@rc or @sourcegraph/amp@latest
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
    echo "Installing @sourcegraph/amp@rc ($DESIRED_VERSION) ..."
    if ! install_with_fallback @sourcegraph/amp@rc; then
        echo "❌ Amp Code RC install failed"
        exit 1
    fi
else
    echo "Installing @sourcegraph/amp@latest ($DESIRED_VERSION) ..."
    if ! install_with_fallback @sourcegraph/amp@latest; then
        echo "❌ Amp Code install failed"
        exit 1
    fi
fi

# Verify
UPDATED_RAW=$(get_amp_version_output)
if ! command -v amp >/dev/null 2>&1; then
    echo "Installation finished, but 'amp' is not on PATH." >&2
    echo "npm global prefix: $(npm config get prefix)" >&2
    echo "Ensure your PATH includes: $(npm bin -g)" >&2
fi
echo "Updated version: ${UPDATED_RAW:-unknown}"
echo "✓ Amp Code update completed"
