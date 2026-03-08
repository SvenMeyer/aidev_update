#!/bin/bash

# Install/update OpenAI Codex CLI to the latest alpha (includes pre-releases).
# Uses the npm dist-tag "alpha" which npm maintains automatically — no manual
# version scraping needed.
#
# Usage: ./codex_update.sh [alpha|latest|beta]   (default: alpha)

TAG="${1:-alpha}"

echo "OpenAI Codex CLI Update Script (tag: $TAG)"

# Resolve the version that the requested tag points to
LATEST_VERSION=$(npm view "@openai/codex@$TAG" version 2>/dev/null)

if [[ -z "$LATEST_VERSION" ]]; then
    echo "❌ Could not resolve version for tag '$TAG'. Check: npm show @openai/codex dist-tags"
    exit 1
fi

echo "Latest $TAG version : $LATEST_VERSION"

# Check currently installed version
CURRENT_VERSION=$(codex --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9.]+)?' | head -1)
if [[ -n "$CURRENT_VERSION" ]]; then
    echo "Installed version   : $CURRENT_VERSION"
    if [[ "$CURRENT_VERSION" == "$LATEST_VERSION" ]]; then
        echo "Already up to date!"
        exit 0
    fi
else
    echo "Installed version   : not installed"
fi

# Install
echo "Installing @openai/codex@$LATEST_VERSION ..."
if ! npm install -g "@openai/codex@$LATEST_VERSION"; then
    echo "❌ Installation failed!"
    exit 1
fi

# Older package versions had no bin field so npm couldn't create the symlink.
# If codex is still not callable, find the native binary and link it manually.
if ! command -v codex &>/dev/null; then
    NPM_BIN=$(npm bin -g 2>/dev/null)
    PKG_DIR=$(npm root -g 2>/dev/null)/@openai/codex
    VENDOR_BINARY=$(find "$PKG_DIR" -maxdepth 5 -type f -name "codex" 2>/dev/null | head -1)

    if [[ -n "$VENDOR_BINARY" && -x "$VENDOR_BINARY" ]]; then
        ln -sf "$VENDOR_BINARY" "$NPM_BIN/codex"
        echo "✓ Symlink fixed: $NPM_BIN/codex -> $VENDOR_BINARY"
    else
        echo "❌ Could not find codex binary — manual intervention required."
        exit 1
    fi
fi

echo "Installed version   : $(codex --version 2>/dev/null || echo 'unknown')"
echo "✓ Done!"
