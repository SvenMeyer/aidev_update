#!/usr/bin/env bash
set -euo pipefail

# https://github.com/entireio/cli

GITHUB_REPO="entireio/cli"
INSTALL_DIR="${HOME}/.local/bin"
CHANNEL="stable"

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

require_commands() {
  local cmd
  for cmd in "$@"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      echo "❌ '$cmd' is required but not installed." >&2
      exit 1
    fi
  done
}

get_checksum_tool() {
  if command -v sha256sum >/dev/null 2>&1; then
    echo "sha256sum"
    return 0
  fi
  if command -v shasum >/dev/null 2>&1; then
    echo "shasum"
    return 0
  fi
  echo "❌ 'sha256sum' or 'shasum' is required for checksum verification." >&2
  exit 1
}

extract_version() {
  echo "$1" | grep -oE '([0-9]+\.){2}[0-9]+(-[0-9A-Za-z.]+)?' | head -1 || true
}

detect_os() {
  case "$(uname -s)" in
    Linux)
      echo "linux"
      ;;
    Darwin)
      echo "darwin"
      ;;
    *)
      echo "❌ Unsupported operating system: $(uname -s)" >&2
      exit 1
      ;;
  esac
}

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64)
      echo "amd64"
      ;;
    arm64|aarch64)
      echo "arm64"
      ;;
    *)
      echo "❌ Unsupported architecture: $(uname -m)" >&2
      exit 1
      ;;
  esac
}

fetch_github_json() {
  local url="$1"
  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    retry_command curl -fsSL -H "Authorization: Bearer ${GITHUB_TOKEN}" "$url"
  else
    retry_command curl -fsSL "$url"
  fi
}

get_latest_version() {
  local channel="$1"
  local url=""

  if [[ "$channel" == "nightly" ]]; then
    url="https://api.github.com/repos/${GITHUB_REPO}/releases?per_page=20"
    fetch_github_json "$url" | python3 -c '
import json, sys
for release in json.load(sys.stdin):
    tag = (release.get("tag_name") or "").lstrip("v")
    if "nightly" in tag:
        print(tag)
        break
'
  else
    url="https://api.github.com/repos/${GITHUB_REPO}/releases/latest"
    fetch_github_json "$url" | python3 -c 'import json, sys; print((json.load(sys.stdin).get("tag_name") or "").lstrip("v"))'
  fi
}

version_is_current_or_newer() {
  local current="$1"
  local latest="$2"

  [[ -n "$current" && -n "$latest" ]] || return 1
  [[ "$(printf '%s\n%s\n' "$current" "$latest" | sort -V | tail -1)" == "$current" ]]
}

verify_checksum() {
  local checksum_tool="$1"
  local file="$2"
  local expected="$3"
  local actual=""

  if [[ "$checksum_tool" == "sha256sum" ]]; then
    actual=$(sha256sum "$file" | awk '{print $1}')
  else
    actual=$(shasum -a 256 "$file" | awk '{print $1}')
  fi

  if [[ "$actual" != "$expected" ]]; then
    echo "❌ Checksum verification failed for $file" >&2
    exit 1
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --channel)
      shift
      [[ $# -gt 0 ]] || {
        echo "Missing value for --channel" >&2
        exit 1
      }
      CHANNEL="$1"
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
  shift
done

case "$CHANNEL" in
  stable|nightly)
    ;;
  *)
    echo "❌ Unsupported channel: $CHANNEL" >&2
    exit 1
    ;;
esac

require_commands curl tar mktemp python3
CHECKSUM_TOOL=$(get_checksum_tool)

echo "Entire Update"
echo "Channel: $CHANNEL"

CURRENT_PATH=$(command -v entire || true)
CURRENT_VERSION=""

if [[ -n "$CURRENT_PATH" ]]; then
  CURRENT_RAW=$(entire --version 2>/dev/null || true)
  CURRENT_VERSION=$(extract_version "$CURRENT_RAW")
  echo "Current version: ${CURRENT_VERSION:-unknown}"
  echo "Current path: $CURRENT_PATH"
else
  echo "entire not currently installed"
fi

echo "Fetching latest version..."
LATEST_VERSION=$(get_latest_version "$CHANNEL")
LATEST_VERSION=$(extract_version "$LATEST_VERSION")

if [[ -z "$LATEST_VERSION" ]]; then
  echo "❌ Could not determine latest Entire version." >&2
  exit 1
fi

echo "Latest version: $LATEST_VERSION"

if version_is_current_or_newer "$CURRENT_VERSION" "$LATEST_VERSION"; then
  if [[ "$CURRENT_VERSION" == "$LATEST_VERSION" ]]; then
    echo "✓ Entire is already up to date ($CURRENT_VERSION)"
  else
    echo "✓ Installed Entire version ($CURRENT_VERSION) is newer than latest ($LATEST_VERSION). Skipping."
  fi
  exit 0
fi

OS=$(detect_os)
ARCH=$(detect_arch)
ARCHIVE_NAME="entire_${OS}_${ARCH}.tar.gz"
DOWNLOAD_URL="https://github.com/${GITHUB_REPO}/releases/download/v${LATEST_VERSION}/${ARCHIVE_NAME}"
CHECKSUMS_URL="https://github.com/${GITHUB_REPO}/releases/download/v${LATEST_VERSION}/checksums.txt"
INSTALL_PATH="${INSTALL_DIR}/entire"

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

ARCHIVE_PATH="${TMP_DIR}/${ARCHIVE_NAME}"
CHECKSUMS_PATH="${TMP_DIR}/checksums.txt"

echo "Downloading release archive..."
retry_command curl -fsSL "$DOWNLOAD_URL" -o "$ARCHIVE_PATH"

echo "Downloading checksums..."
retry_command curl -fsSL "$CHECKSUMS_URL" -o "$CHECKSUMS_PATH"

EXPECTED_CHECKSUM=$(grep -iE "${ARCHIVE_NAME}\$" "$CHECKSUMS_PATH" | awk '{print $1}' || true)
if [[ -z "$EXPECTED_CHECKSUM" ]]; then
  echo "❌ Checksum for ${ARCHIVE_NAME} not found." >&2
  exit 1
fi

echo "Verifying checksum..."
verify_checksum "$CHECKSUM_TOOL" "$ARCHIVE_PATH" "$EXPECTED_CHECKSUM"

echo "Extracting archive..."
tar -xzf "$ARCHIVE_PATH" -C "$TMP_DIR"

if [[ ! -f "${TMP_DIR}/entire" ]]; then
  echo "❌ Extracted archive did not contain the 'entire' binary." >&2
  exit 1
fi

mkdir -p "$INSTALL_DIR"
chmod +x "${TMP_DIR}/entire"
mv "${TMP_DIR}/entire" "$INSTALL_PATH"

INSTALLED_RAW=$("$INSTALL_PATH" --version 2>/dev/null || "$INSTALL_PATH" version 2>/dev/null || true)
INSTALLED_VERSION=$(extract_version "$INSTALLED_RAW")
if [[ "$INSTALLED_VERSION" != "$LATEST_VERSION" ]]; then
  echo "❌ Installed version mismatch: expected $LATEST_VERSION, got ${INSTALLED_VERSION:-unknown}" >&2
  exit 1
fi

RESOLVED_PATH=$(command -v entire || true)
if [[ -n "$RESOLVED_PATH" ]]; then
  echo "Resolved path: $RESOLVED_PATH"
  if [[ "$RESOLVED_PATH" != "$INSTALL_PATH" ]]; then
    echo "⚠ PATH conflict: installed to $INSTALL_PATH but 'entire' resolves to $RESOLVED_PATH" >&2
  fi
else
  echo "⚠ 'entire' is installed to $INSTALL_PATH but not currently on PATH." >&2
fi

echo "Installed version: $INSTALLED_VERSION"
echo "✓ Entire update completed"
