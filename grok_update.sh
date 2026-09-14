#!/bin/bash
set -euo pipefail

# Install or update the official Grok CLI (Grok Build TUI) into ~/.grok/bin.
# https://x.ai/cli
#
# This is the official curl installer + `grok update` path, not the npm
# package (@xai-official/grok). npm still drops a second copy of the same
# native binary and then loses it when nvm switches Node versions.
#
# If grok is missing, run the official installer. If it is already present,
# update only when a newer version is available.

INSTALL_URL="https://x.ai/cli/install.sh"
GROK_BIN_DIR="${GROK_BIN_DIR:-${HOME}/.grok/bin}"

retry_command() {
    local max_attempts=2
    local attempt=1

    while (( attempt <= max_attempts )); do
        if "$@"; then
            return 0
        fi
        echo "Attempt $attempt failed. Retrying..." >&2
        ((attempt++))
        sleep 2
    done

    echo "All attempts failed." >&2
    return 1
}

extract_version() {
    echo "$1" | grep -oE '([0-9]+\.){2}[0-9]+(-[0-9A-Za-z.]+)?' | head -1 || true
}

json_string() {
    local json="$1"
    local field="$2"
    printf '%s' "$json" | sed -n -E 's/.*"'"$field"'"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p' | head -1
}

json_bool() {
    local json="$1"
    local field="$2"
    printf '%s' "$json" | sed -n -E 's/.*"'"$field"'"[[:space:]]*:[[:space:]]*(true|false).*/\1/p' | head -1
}

resolve_grok() {
    local candidate=""

    if [[ -x "${GROK_BIN_DIR}/grok" ]]; then
        printf '%s\n' "${GROK_BIN_DIR}/grok"
        return 0
    fi

    candidate=$(command -v grok 2>/dev/null || true)
    if [[ -n "$candidate" && -x "$candidate" ]]; then
        printf '%s\n' "$candidate"
        return 0
    fi

    return 1
}

warn_if_duplicate_install() {
    local extra=""
    local line=""

    if command -v npm >/dev/null 2>&1 \
        && npm ls -g --depth=0 @xai-official/grok 2>/dev/null | grep -q '@xai-official/grok@'; then
        echo "⚠ npm global @xai-official/grok is also installed." >&2
        echo "  This script keeps a single official copy in ${GROK_BIN_DIR}." >&2
        echo "  Remove the duplicate with: npm uninstall -g @xai-official/grok" >&2
    fi

    extra=$(which -a grok 2>/dev/null | grep -v "^${GROK_BIN_DIR}/grok\$" || true)
    if [[ -n "$extra" ]]; then
        echo "⚠ Extra grok binaries on PATH (canonical is ${GROK_BIN_DIR}/grok):" >&2
        while IFS= read -r line; do
            [[ -n "$line" ]] || continue
            printf '    %s\n' "$line" >&2
        done <<< "$extra"
    fi
}

sync_agent_symlink() {
    local grok_link="${GROK_BIN_DIR}/grok"
    local target=""

    [[ -L "$grok_link" || -e "$grok_link" ]] || return 0
    target=$(readlink "$grok_link" 2>/dev/null || true)
    if [[ -n "$target" ]]; then
        ln -sfn "$target" "${GROK_BIN_DIR}/agent"
    fi
}

install_grok() {
    local installer=""
    local status=0

    if ! command -v curl >/dev/null 2>&1; then
        echo "❌ 'curl' is required but not installed." >&2
        return 1
    fi

    installer=$(mktemp)

    echo "Downloading official installer..."
    if ! retry_command curl -fsSL -o "$installer" "$INSTALL_URL"; then
        rm -f "$installer"
        echo "❌ Failed to download Grok installer from $INSTALL_URL" >&2
        return 1
    fi

    echo "Running official installer..."
    if bash "$installer"; then
        export PATH="${GROK_BIN_DIR}:${PATH}"
        hash -r 2>/dev/null || true
    else
        echo "❌ Grok installer failed!" >&2
        status=1
    fi

    rm -f "$installer"
    return "$status"
}

echo "Grok CLI Update Script"

export PATH="${GROK_BIN_DIR}:${PATH}"
hash -r 2>/dev/null || true

GROK_BIN=$(resolve_grok || true)
CURRENT_VERSION=""
warn_if_duplicate_install

if [[ -n "$GROK_BIN" ]]; then
    CURRENT_VERSION=$(extract_version "$("$GROK_BIN" --version 2>/dev/null || true)")
    echo "Installed version   : ${CURRENT_VERSION:-unknown}"
    echo "Installed path      : $GROK_BIN"
else
    echo "Installed version   : not installed"
fi

if [[ -z "$GROK_BIN" ]]; then
    echo "Installing Grok via https://x.ai/cli/install.sh ..."
    if ! install_grok; then
        exit 1
    fi

    GROK_BIN=$(resolve_grok || true)
    if [[ -z "$GROK_BIN" ]]; then
        echo "❌ Installation finished, but 'grok' could not be located." >&2
        echo "Add ${GROK_BIN_DIR} to PATH if the installer printed that instruction." >&2
        exit 1
    fi

    sync_agent_symlink
    echo "Installed version   : $("$GROK_BIN" --version 2>/dev/null || echo unknown)"
    echo "✓ Grok install completed successfully!"
    exit 0
fi

echo "Checking for a newer Grok version..."
CHECK_JSON=$("$GROK_BIN" update --check --json 2>/dev/null || true)

LATEST_VERSION=$(json_string "${CHECK_JSON:-}" "latestVersion")
UPDATE_AVAILABLE=$(json_bool "${CHECK_JSON:-}" "updateAvailable")
CHECK_CURRENT=$(json_string "${CHECK_JSON:-}" "currentVersion")

if [[ -n "$CHECK_CURRENT" ]]; then
    CURRENT_VERSION="$CHECK_CURRENT"
fi

if [[ -n "$LATEST_VERSION" ]]; then
    echo "Latest version      : $LATEST_VERSION"
else
    echo "Latest version      : unknown"
fi

if [[ "$UPDATE_AVAILABLE" == "false" ]]; then
    echo "✓ Grok is already up to date!"
    exit 0
fi

if [[ "$UPDATE_AVAILABLE" != "true" ]]; then
    if [[ -n "$CURRENT_VERSION" && -n "$LATEST_VERSION" && "$CURRENT_VERSION" == "$LATEST_VERSION" ]]; then
        echo "✓ Grok is already up to date!"
        exit 0
    fi

    if [[ -n "$CURRENT_VERSION" && -n "$LATEST_VERSION" \
        && "$(printf '%s\n%s\n' "$CURRENT_VERSION" "$LATEST_VERSION" | sort -V | tail -1)" == "$CURRENT_VERSION" ]]; then
        echo "✓ Installed Grok version ($CURRENT_VERSION) is newer than latest ($LATEST_VERSION). Skipping."
        exit 0
    fi

    if [[ -z "$LATEST_VERSION" ]]; then
        echo "❌ Could not determine whether a newer Grok version is available." >&2
        exit 1
    fi
fi

echo "Updating Grok (${CURRENT_VERSION:-unknown} -> ${LATEST_VERSION:-latest})..."
if ! retry_command "$GROK_BIN" update; then
    echo "❌ Grok update failed!" >&2
    exit 1
fi

export PATH="${GROK_BIN_DIR}:${PATH}"
hash -r 2>/dev/null || true
GROK_BIN=$(resolve_grok || true)
sync_agent_symlink

UPDATED_VERSION=""
if [[ -n "$GROK_BIN" ]]; then
    UPDATED_VERSION=$(extract_version "$("$GROK_BIN" --version 2>/dev/null || true)")
fi

echo "Updated version     : ${UPDATED_VERSION:-unknown}"

if [[ -n "$LATEST_VERSION" && -n "$UPDATED_VERSION" && "$UPDATED_VERSION" != "$LATEST_VERSION" ]]; then
    echo "❌ Expected Grok $LATEST_VERSION but found $UPDATED_VERSION after update." >&2
    exit 1
fi

echo "✓ Grok update completed successfully!"
