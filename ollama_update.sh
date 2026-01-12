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

# Version comparison that properly handles RC/pre-release versions
# Returns 0 if current >= latest, 1 otherwise
is_current_newer_or_equal() {
  local cur="$1"
  local lat="$2"
  
  # Strip -rc suffix for base version comparison
  local cur_base="${cur%%-rc*}"
  local lat_base="${lat%%-rc*}"
  
  # If base versions are different, compare them
  if [ "$cur_base" != "$lat_base" ]; then
    local higher=$(printf "%s\n%s\n" "$cur_base" "$lat_base" | sort -V | tail -1)
    [ "$higher" = "$cur_base" ] && return 0 || return 1
  fi
  
  # Base versions are the same, now check RC status
  # If current has -rc and latest doesn't, current is older (return 1)
  # If latest has -rc and current doesn't, current is newer (return 0)
  # If both have -rc, compare the RC numbers
  
  if [[ "$cur" =~ -rc([0-9]+)$ ]]; then
    local cur_rc="${BASH_REMATCH[1]}"
    if [[ "$lat" =~ -rc([0-9]+)$ ]]; then
      local lat_rc="${BASH_REMATCH[1]}"
      [ "$cur_rc" -ge "$lat_rc" ] && return 0 || return 1
    else
      # Current is RC, latest is stable -> current is older
      return 1
    fi
  else
    if [[ "$lat" =~ -rc([0-9]+)$ ]]; then
      # Current is stable, latest is RC -> current is newer
      return 0
    else
      # Both are stable and base versions are equal -> they're equal
      return 0
    fi
  fi
}

if [ "$CURRENT_VERSION" != "not installed" ] && [ "$CURRENT_VERSION" != "unknown" ]; then
  if is_current_newer_or_equal "$CURRENT_VERSION" "$LATEST_VERSION" && [ "$CURRENT_VERSION" != "$LATEST_VERSION" ]; then
    echo "✓ Your version ($CURRENT_VERSION) is newer than available ($LATEST_VERSION). Skipping update."
    exit 0
  fi
fi

echo "Update required: $CURRENT_VERSION -> $LATEST_VERSION"

# Set up caching for the binary bundle
CACHE_DIR="$(dirname "$0")/.cache"

# Create cache directory if it doesn't exist
mkdir -p "$CACHE_DIR"

# Detect which format is available (.tgz for stable, .tar.zst for pre-releases)
echo "Detecting available bundle format..."
if curl -sILf "https://ollama.com/download/ollama-linux-amd64.tgz?version=$LATEST_VERSION" >/dev/null 2>&1; then
  BUNDLE_EXT="tgz"
else
  BUNDLE_EXT="tar.zst"
fi
echo "Bundle format: $BUNDLE_EXT"

BUNDLE_FILE="$CACHE_DIR/ollama-linux-amd64-$LATEST_VERSION.$BUNDLE_EXT"

# Check if we have the binary bundle cached, download if not
if [ -f "$BUNDLE_FILE" ]; then
  echo "✓ Using cached binary bundle: $BUNDLE_FILE"
else
  echo "Downloading binary bundle to cache..."
  if ! curl -fL --progress-bar "https://ollama.com/download/ollama-linux-amd64.$BUNDLE_EXT?version=$LATEST_VERSION" -o "$BUNDLE_FILE"; then
    echo "Failed to download binary bundle." >&2
    exit 1
  fi
  echo "✓ Binary bundle cached at: $BUNDLE_FILE"
fi

# Ensure zstd is available if using .tar.zst format
if [ "$BUNDLE_EXT" = "tar.zst" ]; then
  if ! command -v zstd >/dev/null 2>&1; then
    echo "Installing zstd for decompression..."
    if command -v apt-get >/dev/null 2>&1; then
      sudo apt-get install -y zstd
    elif command -v pacman >/dev/null 2>&1; then
      sudo pacman -S --noconfirm zstd
    elif command -v dnf >/dev/null 2>&1; then
      sudo dnf install -y zstd
    else
      echo "Please install zstd manually to extract .tar.zst files." >&2
      exit 1
    fi
  fi
fi

# Request sudo AFTER download completes (or if using cache)
echo "Requesting sudo permission (needed for installation)..."
if ! sudo -v; then
  echo "Failed to get sudo permission." >&2
  exit 1
fi

# Create a modified installer that uses the cached bundle
INSTALLER_PATH="$(dirname "$0")/ollama_install_cached.sh"

# Always download fresh installer to ensure clean state
echo "Downloading official Ollama installer..."
if ! curl -fsSL https://ollama.com/install.sh -o "$INSTALLER_PATH"; then
  echo "Failed to download installer." >&2
  exit 1
fi

# Modify installer to use cached bundle - replace curl download with tar extraction
# This replaces the multi-line: curl ... | $SUDO tar ...
# With appropriate extraction command based on format
if [ "$BUNDLE_EXT" = "tar.zst" ]; then
  # Use zstd for .tar.zst files
  sed -i '/status "Downloading Linux/,/$SUDO tar.*OLLAMA_INSTALL_DIR/c\    zstd -d -c "'"$BUNDLE_FILE"'" | $SUDO tar -x -C "$OLLAMA_INSTALL_DIR"' "$INSTALLER_PATH"
else
  # Use tar -xzf for .tgz files
  sed -i '/status "Downloading Linux/,/$SUDO tar.*OLLAMA_INSTALL_DIR/c\    $SUDO tar -xzf "'"$BUNDLE_FILE"'" -C "$OLLAMA_INSTALL_DIR"' "$INSTALLER_PATH"
fi

echo "Running installer for version $LATEST_VERSION..."
if ! OLLAMA_VERSION="$LATEST_VERSION" sh "$INSTALLER_PATH"; then
  echo "Install failed via official installer." >&2
  exit 1
fi

echo "✓ Installed/updated to $LATEST_VERSION"

# Clean up old cached versions (keep only current)
REMOVED_COUNT=$(find "$CACHE_DIR" \( -name "ollama-linux-amd64-*.tgz" -o -name "ollama-linux-amd64-*.tar.zst" \) ! -name "ollama-linux-amd64-$LATEST_VERSION.$BUNDLE_EXT" -delete -print 2>/dev/null | wc -l)
if [ "$REMOVED_COUNT" -gt 0 ]; then
    echo "Cleaned up $REMOVED_COUNT old cached version(s)"
fi