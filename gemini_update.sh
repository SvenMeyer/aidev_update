#!/bin/bash
set -euo pipefail

echo "Gemini CLI Auto-Update Script"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/gemini_install.sh"

# Ensure required tools are available
if ! command -v npm >/dev/null 2>&1; then
    echo "❌ 'npm' is required but not installed. Please install npm and try again."
    exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
    echo "❌ 'jq' is required but not installed. Please install jq and try again."
    exit 1
fi

extract_semver() {
    local input="$1"
    if [[ "$input" =~ ([0-9]+\.[0-9]+\.[0-9]+(-preview\.[0-9]+)?) ]]; then
        echo "${BASH_REMATCH[1]}"
    else
        echo ""
    fi
}

version_cmp() {
    local a="$1" b="$2"

    if [ -z "${a:-}" ] && [ -z "${b:-}" ]; then
        echo 0
        return
    fi
    if [ -z "${a:-}" ]; then
        echo -1
        return
    fi
    if [ -z "${b:-}" ]; then
        echo 1
        return
    fi

    local a_major a_minor a_patch a_preview b_major b_minor b_patch b_preview

    if [[ "$a" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)(-preview\.([0-9]+))?$ ]]; then
        a_major=${BASH_REMATCH[1]}
        a_minor=${BASH_REMATCH[2]}
        a_patch=${BASH_REMATCH[3]}
        a_preview=${BASH_REMATCH[5]}
    else
        echo "nan"
        return
    fi

    if [[ "$b" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)(-preview\.([0-9]+))?$ ]]; then
        b_major=${BASH_REMATCH[1]}
        b_minor=${BASH_REMATCH[2]}
        b_patch=${BASH_REMATCH[3]}
        b_preview=${BASH_REMATCH[5]}
    else
        echo "nan"
        return
    fi

    if (( a_major != b_major )); then
        if (( a_major > b_major )); then
            echo 1
        else
            echo -1
        fi
        return
    fi

    if (( a_minor != b_minor )); then
        if (( a_minor > b_minor )); then
            echo 1
        else
            echo -1
        fi
        return
    fi

    if (( a_patch != b_patch )); then
        if (( a_patch > b_patch )); then
            echo 1
        else
            echo -1
        fi
        return
    fi

    if [ -z "${a_preview:-}" ] && [ -z "${b_preview:-}" ]; then
        echo 0
        return
    fi

    if [ -z "${a_preview:-}" ]; then
        echo 1
        return
    fi

    if [ -z "${b_preview:-}" ]; then
        echo -1
        return
    fi

    if (( a_preview > b_preview )); then
        echo 1
    elif (( a_preview < b_preview )); then
        echo -1
    else
        echo 0
    fi
}

version_lt() {
    local cmp
    cmp=$(version_cmp "$1" "$2")
    if [ "$cmp" = "nan" ]; then
        [[ "$1" < "$2" ]]
    else
        [ "$cmp" -eq -1 ]
    fi
}

CURRENT_VERSION=""
if command -v gemini >/dev/null 2>&1; then
    CURRENT_VERSION=$(extract_semver "$(gemini --version 2>/dev/null || true)")
fi

if [ -n "$CURRENT_VERSION" ]; then
    echo "Current version: $CURRENT_VERSION"
else
    echo "Current version: Not installed"
fi

echo "Fetching latest version information..."
VERSIONS_JSON=$(retry_command npm view @google/gemini-cli versions --json || true)

if [ -z "${VERSIONS_JSON:-}" ]; then
    echo "❌ Unable to retrieve version information."
    exit 1
fi

LATEST_STABLE_RAW=$(echo "$VERSIONS_JSON" | jq -r '[.[] | select(test("nightly")|not) | select(test("-preview")|not)][-1] // ""')
LATEST_PREVIEW_RAW=$(echo "$VERSIONS_JSON" | jq -r '[.[] | select(test("nightly")|not) | select(test("-preview"))][-1] // ""')

LATEST_STABLE=$(extract_semver "$LATEST_STABLE_RAW")
LATEST_PREVIEW=$(extract_semver "$LATEST_PREVIEW_RAW")

if [ -n "$LATEST_STABLE" ]; then
    echo "Latest stable release: $LATEST_STABLE"
else
    echo "Latest stable release: None found"
fi

if [ -n "$LATEST_PREVIEW" ]; then
    echo "Latest preview release: $LATEST_PREVIEW"
else
    echo "Latest preview release: None found"
fi

TARGET_VERSION=""
TARGET_CHANNEL=""

if [ -n "$LATEST_STABLE" ] && version_lt "$CURRENT_VERSION" "$LATEST_STABLE"; then
    TARGET_VERSION="$LATEST_STABLE"
    TARGET_CHANNEL="stable"
fi

if [ -n "$LATEST_PREVIEW" ] && version_lt "$CURRENT_VERSION" "$LATEST_PREVIEW"; then
    if [ -z "$TARGET_VERSION" ] || version_lt "$TARGET_VERSION" "$LATEST_PREVIEW"; then
        TARGET_VERSION="$LATEST_PREVIEW"
        TARGET_CHANNEL="preview"
    fi
fi

if [ -z "$TARGET_VERSION" ]; then
    echo "✓ Gemini CLI is already up to date!"
    exit 0
fi

echo "Selected $TARGET_CHANNEL version: $TARGET_VERSION"

if install_gemini_cli "$TARGET_VERSION"; then
    echo "Updated version:"
    gemini --version
    echo "✓ Gemini CLI update completed successfully!"
else
    echo "❌ Gemini CLI update failed!"
    exit 1
fi
