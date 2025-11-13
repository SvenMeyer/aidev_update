#!/bin/bash

set -eo pipefail

echo "Ollama"

# Detect current version (normalize to strip leading 'v')
if command -v ollama >/dev/null 2>&1; then
  RAW_CUR=$(ollama --version 2>&1)
  CURRENT_VERSION=$(echo "$RAW_CUR" | grep -Eo 'v?[0-9]+\.[0-9]+\.[0-9]+(-rc[0-9]+)?' | head -n1 | sed 's/^v//')
  [ -z "$CURRENT_VERSION" ] && CURRENT_VERSION="unknown"
else
  CURRENT_VERSION="not installed"
fi
echo "Current version: $CURRENT_VERSION"

# Include pre-releases by default; override with env INCLUDE_PRE_RELEASE=false
INCLUDE_PRE_RELEASE=${INCLUDE_PRE_RELEASE:-true}

echo "Fetching latest version information..."

get_latest_version() {
  local ver=""
  if [ "${INCLUDE_PRE_RELEASE}" = "true" ]; then
    ver=$( (curl -s https://api.github.com/repos/ollama/ollama/releases \
      | grep -m1 '"tag_name":' \
      | sed -E 's/.*"tag_name": "v?([^"]+)".*/\1/') || true )
    if [ -n "$ver" ]; then echo "$ver"; return 0; fi
  fi
  ver=$( (curl -s https://api.github.com/repos/ollama/ollama/releases/latest \
    | grep -o '"tag_name": "[^"]*' \
    | sed -E 's/"tag_name": "v?//') || true )
  if [ -n "$ver" ]; then echo "$ver"; return 0; fi
  ver=$( (curl -s https://api.github.com/repos/ollama/ollama/tags \
    | grep -m1 '"name":' \
    | sed -E 's/.*"name": "v?([^"]+)".*/\1/') || true )
  [ -n "$ver" ] && echo "$ver"
}

LATEST_VERSION=$(get_latest_version || true)
if [ -z "$LATEST_VERSION" ]; then
  echo "Could not determine latest version (GitHub API issue or no network). Skipping update."
  exit 0
fi
if [ "$INCLUDE_PRE_RELEASE" = "true" ]; then
  echo "Latest version (including pre-releases): $LATEST_VERSION"
else
  echo "Latest version: $LATEST_VERSION"
fi

# Early exits when up-to-date or newer
if [ "$CURRENT_VERSION" = "$LATEST_VERSION" ]; then
  echo "✓ Ollama is already up to date"
  exit 0
fi

if [ "$CURRENT_VERSION" != "not installed" ] && [ "$CURRENT_VERSION" != "unknown" ]; then
  HIGHER=$(printf "%s\n%s\n" "$CURRENT_VERSION" "$LATEST_VERSION" | sort -V | tail -1)
  if [ "$HIGHER" = "$CURRENT_VERSION" ] && [ "$CURRENT_VERSION" != "$LATEST_VERSION" ]; then
    echo "✓ Your version ($CURRENT_VERSION) is newer than available ($LATEST_VERSION). Skipping update."
    exit 0
  fi
fi

echo "Update required: $CURRENT_VERSION -> $LATEST_VERSION"

echo "Running official installer for $LATEST_VERSION ..."
# Install the exact version we detected (supports RCs) via upstream installer.
# Note: The installer may prompt for sudo; this script itself does not handle sudo.
if ! curl -fsSL https://ollama.com/install.sh | OLLAMA_VERSION="$LATEST_VERSION" sh; then
  echo "Install failed via official installer." >&2
  exit 1
fi

echo "✓ Installed/updated to $LATEST_VERSION"