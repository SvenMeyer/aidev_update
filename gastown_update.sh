#!/bin/bash
set -euo pipefail

INSTALL_DIR="${HOME}/.local/bin"
GT_HOME="${GT_HOME:-${HOME}/gt}"

GT_REPO="gastownhall/gastown"
GT_RELEASES_API_URL="https://api.github.com/repos/${GT_REPO}/releases"

DOLT_REPO="dolthub/dolt"
DOLT_LATEST_API_URL="https://api.github.com/repos/${DOLT_REPO}/releases/latest"

# Use the built-in `claude` agent (Claude Code CLI). It authenticates with the
# local Claude subscription/login — no API key or separate plan required.
DEFAULT_AGENT_NAME="claude"

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

verify_checksum_file_entry() {
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

verify_expected_sha() {
    local expected_sha="$1"
    local asset_path="$2"
    local actual_sha=""

    actual_sha=$(sha256_file "$asset_path") || {
        echo "❌ No SHA256 tool found (need sha256sum, shasum, or openssl)."
        exit 1
    }

    if [[ "$actual_sha" != "$expected_sha" ]]; then
        echo "❌ Checksum mismatch for $(basename "$asset_path")"
        exit 1
    fi
}

version_is_same_or_newer() {
    local current="$1"
    local target="$2"

    [[ -n "$current" && -n "$target" ]] || return 1
    [[ "$(printf '%s\n%s\n' "$current" "$target" | sort -V | tail -1)" == "$current" ]]
}

get_latest_stable_gt_version() {
    local version=""

    version=$(retry_command curl -fsSL "$GT_RELEASES_API_URL" \
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

get_gt_version_raw() {
    if command -v gt >/dev/null 2>&1; then
        gt version 2>/dev/null || gt --version 2>/dev/null || true
    fi
}

get_dolt_version_raw() {
    if command -v dolt >/dev/null 2>&1; then
        dolt version 2>/dev/null || true
    fi
}

install_dolt_if_needed() {
    local platform_suffix=""
    local current_version_raw=""
    local current_version=""
    local latest_info=""
    local latest_version=""
    local asset_name=""
    local asset_url=""
    local asset_sha=""
    local tmpdir=""
    local archive_path=""

    current_version_raw=$(get_dolt_version_raw)
    current_version=$(extract_version "${current_version_raw:-}")

    echo "Checking Dolt..."
    if [[ -n "$current_version_raw" ]]; then
        echo "Installed Dolt      : $current_version_raw"
    else
        echo "Installed Dolt      : not installed"
    fi

    case "$(detect_platform)" in
        linux_amd64)
            platform_suffix="linux-amd64"
            ;;
        linux_arm64)
            platform_suffix="linux-arm64"
            ;;
        darwin_amd64)
            platform_suffix="darwin-amd64"
            ;;
        darwin_arm64)
            platform_suffix="darwin-arm64"
            ;;
        *)
            echo "❌ Unsupported platform for Dolt installation: $(detect_platform)"
            exit 1
            ;;
    esac

    latest_info=$(retry_command curl -fsSL "$DOLT_LATEST_API_URL" \
        | python3 -c 'import json,sys
platform = sys.argv[1]
data = json.load(sys.stdin)
tag = (data.get("tag_name") or "").lstrip("v")
asset_name = f"dolt-{platform}.tar.gz"
digest = ""
url = ""
for asset in data.get("assets", []):
    if asset.get("name") == asset_name:
        digest = (asset.get("digest") or "").replace("sha256:", "")
        url = asset.get("browser_download_url") or ""
        break
print(tag)
print(asset_name)
print(url)
print(digest)' "$platform_suffix" \
        || true)

    latest_version=$(printf '%s\n' "$latest_info" | sed -n '1p')
    asset_name=$(printf '%s\n' "$latest_info" | sed -n '2p')
    asset_url=$(printf '%s\n' "$latest_info" | sed -n '3p')
    asset_sha=$(printf '%s\n' "$latest_info" | sed -n '4p')

    latest_version=$(normalize_version "$latest_version" || true)

    if [[ -z "$latest_version" || -z "$asset_name" || -z "$asset_url" || -z "$asset_sha" ]]; then
        echo "❌ Could not determine the latest Dolt release asset."
        exit 1
    fi

    echo "Latest Dolt         : $latest_version"
    if [[ -n "$current_version" ]] && version_is_same_or_newer "$current_version" "$latest_version"; then
        echo "✓ Dolt already satisfies the required version."
        return 0
    fi

    echo "Installing Dolt..."
    tmpdir=$(mktemp -d)
    archive_path="${tmpdir}/${asset_name}"
    trap 'rm -rf "$tmpdir"' RETURN

    retry_command curl -fsSL -o "$archive_path" "$asset_url"
    verify_expected_sha "$asset_sha" "$archive_path"

    tar -xzf "$archive_path" -C "$tmpdir"
    mkdir -p "$INSTALL_DIR"
    install -m 755 "${tmpdir}/dolt-${platform_suffix}/bin/dolt" "${INSTALL_DIR}/dolt"
    hash -r 2>/dev/null || true

    echo "Updated Dolt        : $(dolt version 2>/dev/null || echo unknown)"
}

install_gt_if_needed() {
    local platform=""
    local current_version_raw=""
    local current_version=""
    local latest_version=""
    local asset_name=""
    local archive_path=""
    local checksums_path=""
    local download_url=""
    local checksums_url=""
    local tmpdir=""

    echo "Gastown Update Script"

    current_version_raw=$(get_gt_version_raw)
    current_version=$(extract_version "${current_version_raw:-}")

    if [[ -n "$current_version_raw" ]]; then
        echo "Installed Gastown   : $current_version_raw"
    else
        echo "Installed Gastown   : not installed"
    fi

    latest_version=$(get_latest_stable_gt_version)
    if [[ -z "$latest_version" ]]; then
        echo "❌ Could not determine the latest stable Gastown version."
        exit 1
    fi
    echo "Latest stable       : $latest_version"

    if [[ -n "$current_version" ]] && version_is_same_or_newer "$current_version" "$latest_version"; then
        echo "✓ Gastown already up to date."
        return 0
    fi

    platform=$(detect_platform)
    asset_name="gastown_${latest_version}_${platform}.tar.gz"
    download_url="https://github.com/${GT_REPO}/releases/download/v${latest_version}/${asset_name}"
    checksums_url="https://github.com/${GT_REPO}/releases/download/v${latest_version}/gastown_${latest_version}_checksums.txt"

    echo "Installing Gastown from stable release assets..."
    tmpdir=$(mktemp -d)
    archive_path="${tmpdir}/${asset_name}"
    checksums_path="${tmpdir}/gastown_${latest_version}_checksums.txt"
    trap 'rm -rf "$tmpdir"' RETURN

    retry_command curl -fsSL -o "$archive_path" "$download_url"
    retry_command curl -fsSL -o "$checksums_path" "$checksums_url"
    verify_checksum_file_entry "$checksums_path" "$asset_name" "$archive_path"

    tar -xzf "$archive_path" -C "$tmpdir"
    mkdir -p "$INSTALL_DIR"
    install -m 755 "${tmpdir}/gt" "${INSTALL_DIR}/gt"
    hash -r 2>/dev/null || true

    echo "Updated Gastown     : $(gt version 2>/dev/null || echo unknown)"
}

ensure_gt_home_and_default_agent() {
    export PATH="${INSTALL_DIR}:${PATH}"

    if [[ ! -f "${GT_HOME}/CLAUDE.md" ]]; then
        echo "Initializing Gastown HQ at ${GT_HOME}..."
        gt install "$GT_HOME" --git
    else
        echo "Gastown HQ          : ${GT_HOME}"
    fi

    echo "Configuring default agent..."
    (
        cd "$GT_HOME"
        # `claude` is a built-in agent, so no `gt config agent set` is needed —
        # just point the town-global default at it.
        gt config default-agent "$DEFAULT_AGENT_NAME"
        echo "Default agent       : $(gt config default-agent)"
    )
}

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

if ! command -v install >/dev/null 2>&1; then
    echo "❌ 'install' is required but not installed."
    exit 1
fi

if ! command -v git >/dev/null 2>&1; then
    echo "❌ 'git' is required but not installed."
    exit 1
fi

if ! command -v claude >/dev/null 2>&1; then
    echo "❌ 'claude' (Claude Code CLI) is required but not installed."
    exit 1
fi

export PATH="${INSTALL_DIR}:${PATH}"

install_dolt_if_needed
install_gt_if_needed
ensure_gt_home_and_default_agent

echo "✓ Gastown update completed successfully!"
