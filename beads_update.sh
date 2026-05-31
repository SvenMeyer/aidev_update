#!/bin/bash
set -euo pipefail

BEADS_REPO="gastownhall/beads"
BEADS_RELEASES_API_URL="https://api.github.com/repos/${BEADS_REPO}/releases"
INSTALL_DIR="${HOME}/.local/bin"

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

normalize_version() {
    local version="${1#v}"
    if [[ "$version" =~ ^([0-9]+\.){2}[0-9]+(-[0-9A-Za-z.]+)?$ ]]; then
        printf '%s\n' "$version"
        return 0
    fi
    return 1
}

extract_version() {
    local raw="$1"
    local version

    version=$(echo "$raw" | grep -oE '([0-9]+\.){2}[0-9]+(-[0-9A-Za-z.]+)?' | head -1 || true)
    [[ -n "$version" ]] || return 0
    normalize_version "$version" || true
}

get_current_version_raw() {
    if command -v bd >/dev/null 2>&1; then
        bd version 2>/dev/null || bd --version 2>/dev/null || true
        return 0
    fi

    if command -v beads >/dev/null 2>&1; then
        beads --version 2>/dev/null || true
    fi
}

get_latest_version() {
    local version=""

    version=$(retry_command curl -fsSL "$BEADS_RELEASES_API_URL" \
        | python3 -c 'import json,sys
for release in json.load(sys.stdin):
    if release.get("draft") or release.get("prerelease"):
        continue
    tag = (release.get("tag_name") or "").lstrip("v")
    if tag:
        print(tag)
        break' \
        || true)
    normalize_version "$version" || true
}

detect_platform() {
    local os=""
    local arch=""

    case "$(uname -s)" in
        Linux)
            os="linux"
            ;;
        Darwin)
            os="darwin"
            ;;
        FreeBSD)
            os="freebsd"
            ;;
        *)
            echo "❌ Unsupported operating system: $(uname -s)"
            exit 1
            ;;
    esac

    case "$(uname -m)" in
        x86_64|amd64)
            arch="amd64"
            ;;
        aarch64|arm64)
            arch="arm64"
            ;;
        *)
            echo "❌ Unsupported architecture: $(uname -m)"
            exit 1
            ;;
    esac

    printf '%s_%s\n' "$os" "$arch"
}

sha256_file() {
    local file_path="$1"

    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$file_path" | awk '{print $1}'
        return 0
    fi

    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$file_path" | awk '{print $1}'
        return 0
    fi

    if command -v openssl >/dev/null 2>&1; then
        openssl dgst -sha256 "$file_path" | awk '{print $2}'
        return 0
    fi

    return 1
}

verify_checksum() {
    local checksums_path="$1"
    local asset_name="$2"
    local asset_path="$3"
    local expected=""
    local actual=""

    expected=$(awk -v target="$asset_name" '{name=$2; sub(/^\*/, "", name); if (name == target) {print $1; exit}}' "$checksums_path")
    if [[ -z "$expected" ]]; then
        echo "❌ No checksum found for ${asset_name}"
        exit 1
    fi

    actual=$(sha256_file "$asset_path") || {
        echo "❌ No SHA256 tool found (need sha256sum, shasum, or openssl)."
        exit 1
    }

    if [[ "$expected" != "$actual" ]]; then
        echo "❌ Checksum mismatch for ${asset_name}"
        exit 1
    fi
}

echo "Beads Update Script"

if ! command -v curl >/dev/null 2>&1; then
    echo "❌ 'curl' is required but not installed."
    exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
    echo "❌ 'python3' is required but not installed."
    exit 1
fi

if ! command -v tar >/dev/null 2>&1; then
    echo "❌ 'tar' is required but not installed."
    exit 1
fi

CURRENT_VERSION_RAW=$(get_current_version_raw)
CURRENT_VERSION=$(extract_version "${CURRENT_VERSION_RAW:-}")

if [[ -n "$CURRENT_VERSION_RAW" ]]; then
    echo "Installed version   : $CURRENT_VERSION_RAW"
else
    echo "Installed version   : not installed"
fi

echo "Fetching latest release..."
LATEST_VERSION=$(get_latest_version)
if [[ -z "$LATEST_VERSION" ]]; then
    echo "❌ Could not determine the latest stable Beads version."
    exit 1
fi
echo "Latest stable       : $LATEST_VERSION"

if [[ -n "$CURRENT_VERSION" ]]; then
    if [[ "$CURRENT_VERSION" == "$LATEST_VERSION" ]]; then
        echo "✓ Beads already up to date."
        exit 0
    fi

    if [[ "$(printf '%s\n%s\n' "$CURRENT_VERSION" "$LATEST_VERSION" | sort -V | tail -1)" == "$CURRENT_VERSION" ]]; then
        echo "✓ Installed Beads version ($CURRENT_VERSION) is newer than latest release ($LATEST_VERSION). Skipping."
        exit 0
    fi
fi

PLATFORM=$(detect_platform)
ASSET_NAME="beads_${LATEST_VERSION}_${PLATFORM}.tar.gz"
DOWNLOAD_URL="https://github.com/${BEADS_REPO}/releases/download/v${LATEST_VERSION}/${ASSET_NAME}"
CHECKSUMS_URL="https://github.com/${BEADS_REPO}/releases/download/v${LATEST_VERSION}/checksums.txt"

echo "Updating Beads from stable release assets..."
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

ARCHIVE_PATH="${TMPDIR}/${ASSET_NAME}"
CHECKSUMS_PATH="${TMPDIR}/checksums.txt"

retry_command curl -fsSL -o "$ARCHIVE_PATH" "$DOWNLOAD_URL"
retry_command curl -fsSL -o "$CHECKSUMS_PATH" "$CHECKSUMS_URL"
verify_checksum "$CHECKSUMS_PATH" "$ASSET_NAME" "$ARCHIVE_PATH"

tar -xzf "$ARCHIVE_PATH" -C "$TMPDIR"

mkdir -p "$INSTALL_DIR"
install -m 755 "${TMPDIR}/bd" "${INSTALL_DIR}/bd"
ln -sfn bd "${INSTALL_DIR}/beads"
hash -r 2>/dev/null || true

UPDATED_VERSION_RAW=$(get_current_version_raw)
UPDATED_VERSION=$(extract_version "${UPDATED_VERSION_RAW:-}")

if [[ -z "$UPDATED_VERSION" ]]; then
    echo "❌ Beads update finished, but no installed version could be verified."
    exit 1
fi

echo "Updated version     : $UPDATED_VERSION_RAW"

if [[ "$UPDATED_VERSION" != "$LATEST_VERSION" ]]; then
    echo "❌ Expected Beads $LATEST_VERSION but found $UPDATED_VERSION after update."
    exit 1
fi

echo "✓ Beads update completed successfully!"
