#!/bin/bash

# Install/update OpenAI Codex CLI to the latest alpha (includes pre-releases).
# Uses the npm dist-tag "alpha" which npm maintains automatically — no manual
# version scraping needed.
# Pins the managed daemon to the installed CLI package (may interrupt running work).
#
# Usage: ./codex_update.sh [alpha|latest|beta]   (default: alpha)

TAG="${1:-alpha}"

echo "OpenAI Codex CLI Update Script (tag: $TAG)"

update_daemon() {
    local update_help version_info cli_version managed_version server_version
    # Older releases do not have managed daemon updates. Never fall back to
    # killing Codex processes or downloading the stable daemon package.
    if ! update_help=$(codex app-server daemon update --help 2>/dev/null) ||
        [[ "$update_help" != *--from-cli* || "$update_help" != *--yes* ]]; then
        echo "⚠ This CLI does not support daemon updates from the CLI; skipping daemon update."
        return 0
    fi

    # Avoid interrupting work when both the managed package and running server
    # already match. The CLI emits these version fields as JSON strings.
    if version_info=$(codex app-server daemon version 2>/dev/null); then
        cli_version=$(sed -n 's/.*"cliVersion":[[:space:]]*"\([^"]*\)".*/\1/p' <<< "$version_info")
        managed_version=$(sed -n 's/.*"managedCodexVersion":[[:space:]]*"\([^"]*\)".*/\1/p' <<< "$version_info")
        server_version=$(sed -n 's/.*"appServerVersion":[[:space:]]*"\([^"]*\)".*/\1/p' <<< "$version_info")
        if [[ -n "$cli_version" && "$managed_version" == "$cli_version" && "$server_version" == "$cli_version" ]]; then
            echo "Managed daemon already matches the CLI ($cli_version)."
            return 0
        fi
    fi

    echo "Updating managed daemon to the installed CLI package (may interrupt running work) ..."
    if ! codex app-server daemon update --from-cli --yes; then
        echo "❌ CLI is installed, but the daemon update failed."
        return 1
    fi
    echo "✓ Managed daemon pinned to the installed CLI package."
}

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
        echo "CLI already up to date!"
        update_daemon || exit 1
        echo "✓ Done!"
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
update_daemon || exit 1
echo "✓ Done!"
