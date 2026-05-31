#!/bin/bash
set -euo pipefail

PACKAGE_NAME="gastown-gui"

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

extract_current_version() {
    npm list -g "$PACKAGE_NAME" --depth=0 --json 2>/dev/null \
        | python3 -c 'import json,sys
data = json.load(sys.stdin)
deps = data.get("dependencies") or {}
pkg = deps.get(sys.argv[1]) or {}
print(pkg.get("version", ""))' "$PACKAGE_NAME" \
        || true
}

echo "Gastown GUI Update Script"

if ! command -v npm >/dev/null 2>&1; then
    echo "❌ 'npm' is required but not installed."
    exit 1
fi

if ! command -v node >/dev/null 2>&1; then
    echo "❌ 'node' is required but not installed."
    exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
    echo "❌ 'python3' is required but not installed."
    exit 1
fi

CURRENT_VERSION=$(extract_current_version)
if [[ -n "$CURRENT_VERSION" ]]; then
    echo "Installed version   : $CURRENT_VERSION"
else
    echo "Installed version   : not installed"
fi

LATEST_VERSION=$(retry_command npm view "$PACKAGE_NAME" version 2>/dev/null || true)
if [[ -z "$LATEST_VERSION" ]]; then
    echo "❌ Could not determine the latest ${PACKAGE_NAME} version."
    exit 1
fi
echo "Latest version      : $LATEST_VERSION"

if [[ -n "$CURRENT_VERSION" && "$CURRENT_VERSION" == "$LATEST_VERSION" ]]; then
    echo "✓ ${PACKAGE_NAME} already up to date."
else
    echo "Installing ${PACKAGE_NAME}@${LATEST_VERSION}..."
    retry_command npm install -g "${PACKAGE_NAME}@${LATEST_VERSION}"
fi

if ! command -v gastown-gui >/dev/null 2>&1; then
    echo "❌ gastown-gui command not found after installation." >&2
    exit 1
fi

echo "CLI version         : $(gastown-gui version 2>/dev/null || echo unknown)"
GT_ROOT="${GT_ROOT:-${HOME}/gt}" gastown-gui doctor
echo "✓ Gastown GUI update completed successfully!"
