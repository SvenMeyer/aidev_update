#!/bin/bash
set -euo pipefail

# Headroom AI update script
# https://github.com/chopratejas/headroom/releases
#
# Usage:
#   ./headroom_update.sh                   # normal update to latest
#   ./headroom_update.sh --override-version X.Y.Z  # force install a specific version
#   ./headroom_update.sh --kill-port-owner          # allow killing non-headroom process on 8787

HEADROOM_HOST="127.0.0.1"
HEADROOM_PORT=8787
HEADROOM_REPO="chopratejas/headroom"
DEPLOY_ROOT="${HOME}/.headroom/deploy"
HEALTH_CHECK_ATTEMPTS=12
HEALTH_CHECK_INTERVAL=5

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
OVERRIDE_VERSION=""
KILL_PORT_OWNER=false

normalize_version() {
    local version="${1#v}"
    if [[ "$version" =~ ^([0-9]+\.){2}[0-9]+(-[0-9A-Za-z.]+)?$ ]]; then
        printf '%s\n' "$version"
        return 0
    fi
    return 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --override-version)
            if [[ $# -lt 2 || -z "${2:-}" || "${2:-}" == --* ]]; then
                echo "Missing value for --override-version" >&2
                exit 1
            fi
            if ! OVERRIDE_VERSION=$(normalize_version "$2"); then
                echo "Invalid override version: $2" >&2
                exit 1
            fi
            shift 2
            ;;
        --kill-port-owner)
            KILL_PORT_OWNER=true
            shift
            ;;
        *)
            echo "Unknown argument: $1" >&2
            exit 1
            ;;
    esac
done

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

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

# Extract semver from version output (handles "headroom, version X.Y.Z")
extract_version() {
    local version
    version=$(echo "$1" | grep -oE '([0-9]+\.){2}[0-9]+(-[0-9A-Za-z.]+)?' | head -1 || true)
    [[ -n "$version" ]] || return 0
    normalize_version "$version" || true
}

# Get the latest release version from GitHub API (primary)
# Falls back to scraping the releases HTML page
get_latest_version() {
    local ver=""

    ver=$(curl -fsSL "https://api.github.com/repos/${HEADROOM_REPO}/releases/latest" 2>/dev/null \
        | python3 -c 'import json,sys; print((json.load(sys.stdin).get("tag_name") or "").lstrip("v"))' 2>/dev/null \
        || true)
    ver=$(normalize_version "$ver" 2>/dev/null || true)
    if [[ -n "$ver" ]]; then
        echo "$ver"
        return 0
    fi

    ver=$(curl -fsSL "https://github.com/${HEADROOM_REPO}/releases" 2>/dev/null \
        | grep -oE '/releases/tag/v?[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?' \
        | head -1 \
        | sed -E 's|.*/tag/v?||' || true)
    ver=$(normalize_version "$ver" 2>/dev/null || true)
    if [[ -n "$ver" ]]; then
        echo "$ver"
        return 0
    fi

    return 1
}

# Find deployment profiles that use HEADROOM_PORT
find_profiles_on_port() {
    local port="$1"
    if [[ -d "$DEPLOY_ROOT" ]]; then
        for manifest in "$DEPLOY_ROOT"/*/manifest.json; do
            [[ -f "$manifest" ]] || continue
            python3 - "$manifest" "$port" <<'PY' 2>/dev/null || true
import json
import sys

manifest_path, target_port = sys.argv[1], sys.argv[2]
with open(manifest_path) as f:
    data = json.load(f)

if str(data.get("port", "")) == target_port:
    print(f"{data.get('updated_at', '')}\t{data.get('profile', '')}\t{data.get('health_url', '')}")
PY
        done
    fi
}

# Get PID of the process listening on a given port (tcp, IPv4)
get_port_owner() {
    local port="$1"
    lsof -nP -iTCP:"${port}" -sTCP:LISTEN 2>/dev/null | awk 'NR>1 {print $1, $2; exit}' || true
}

is_healthy_response() {
    python3 -c 'import json, sys; d=json.load(sys.stdin); status=str(d.get("status", "")).lower(); ready=str(d.get("ready", "")).lower(); sys.exit(0 if status == "healthy" or ready == "true" else 1)' \
        2>/dev/null
}

wait_for_health() {
    local response=""
    local url=""
    local attempt=1
    local -a urls=("$@")

    while (( attempt <= HEALTH_CHECK_ATTEMPTS )); do
        for url in "${urls[@]}"; do
            [[ -n "$url" ]] || continue
            response=$(curl -fsSL "$url" 2>/dev/null || true)
            if [[ -n "$response" ]] && is_healthy_response <<<"$response"; then
                printf '%s\n' "$url"
                return 0
            fi
        done
        if (( attempt == HEALTH_CHECK_ATTEMPTS )); then
            break
        fi
        ((attempt++))
        sleep "$HEALTH_CHECK_INTERVAL"
    done

    return 1
}

start_direct_proxy() {
    local log_dir="${HOME}/.headroom/logs"
    local log_file="${log_dir}/proxy.log"

    mkdir -p "$log_dir"
    echo "Starting headroom proxy in background (log: $log_file)..."
    nohup headroom proxy >"$log_file" 2>&1 &
    echo "Proxy PID: $!"
}

# ---------------------------------------------------------------------------
# Main logic
# ---------------------------------------------------------------------------

echo "Headroom Update"

# Check dependencies
require_commands pipx curl python3 lsof

HEADROOM_AVAILABLE=false
if command -v headroom >/dev/null 2>&1; then
    HEADROOM_AVAILABLE=true
fi

# --- Resolve target version ------------------------------------------------
if [[ -n "$OVERRIDE_VERSION" ]]; then
    LATEST_VERSION="$OVERRIDE_VERSION"
    echo "Override version: $LATEST_VERSION"
else
    echo "Fetching latest version from GitHub..."
    LATEST_VERSION=$(get_latest_version || true)
    if [[ -z "$LATEST_VERSION" ]]; then
        echo "Could not determine latest version. Skipping update."
        exit 0
    fi
    echo "Latest version: $LATEST_VERSION"
fi

# --- Detect current version ------------------------------------------------
CURRENT_VERSION_RAW=""
if [[ "$HEADROOM_AVAILABLE" == "true" ]]; then
    CURRENT_VERSION_RAW=$(headroom --version 2>/dev/null || true)
fi
CURRENT_VERSION=$(extract_version "$CURRENT_VERSION_RAW")
echo "Current version: ${CURRENT_VERSION:-not installed}"

# --- Version comparison -----------------------------------------------------
if [[ -z "$OVERRIDE_VERSION" ]]; then
    if [[ -n "$CURRENT_VERSION" && -n "$LATEST_VERSION" ]]; then
        if [[ "$CURRENT_VERSION" == "$LATEST_VERSION" ]]; then
            echo "✓ Headroom already up to date ($CURRENT_VERSION)"
            exit 0
        fi
        # Is current newer than latest? (e.g. local dev build)
        if [[ "$(printf '%s\n%s\n' "$CURRENT_VERSION" "$LATEST_VERSION" | sort -V | tail -1)" == "$CURRENT_VERSION" ]] \
            && [[ "$CURRENT_VERSION" != "$LATEST_VERSION" ]]; then
            echo "✓ Installed version ($CURRENT_VERSION) is newer than latest ($LATEST_VERSION). Skipping."
            exit 0
        fi
    fi
fi

echo "Update required: ${CURRENT_VERSION:-not installed} -> $LATEST_VERSION"

# --- Stop Headroom ----------------------------------------------------------

# 1) Try manifest-backed stop for each profile on the port
PROFILES=()
PRIMARY_PROFILE=""
PRIMARY_HEALTH_URL=""
PRIMARY_UPDATED_AT=""
while IFS=$'\t' read -r updated_at profile health_url; do
    [[ -n "$profile" ]] || continue
    PROFILES+=("$profile")
    if [[ -z "$PRIMARY_PROFILE" || "$updated_at" > "$PRIMARY_UPDATED_AT" ]]; then
        PRIMARY_PROFILE="$profile"
        PRIMARY_HEALTH_URL="$health_url"
        PRIMARY_UPDATED_AT="$updated_at"
    fi
done < <(find_profiles_on_port "$HEADROOM_PORT")

if [[ ${#PROFILES[@]} -gt 1 ]]; then
    echo "⚠ Multiple deployment profiles on port $HEADROOM_PORT: ${PROFILES[*]}"
    echo "  Stopping all of them and restarting the newest profile: $PRIMARY_PROFILE"
fi

if [[ "$HEADROOM_AVAILABLE" == "true" ]]; then
    for profile in "${PROFILES[@]}"; do
        echo "Stopping manifest profile '$profile'..."
        headroom install stop --profile "$profile" 2>/dev/null || true
    done
elif [[ ${#PROFILES[@]} -gt 0 ]]; then
    echo "⚠ Found manifest profiles, but 'headroom' is not currently on PATH. Skipping manifest stop step." >&2
fi

# 2) Kill any remaining headroom process on the port
PORT_OWNER=$(get_port_owner "$HEADROOM_PORT")
if [[ -n "$PORT_OWNER" ]]; then
    OWNER_NAME=$(echo "$PORT_OWNER" | awk '{print $1}')
    OWNER_PID=$(echo "$PORT_OWNER" | awk '{print $2}')

    if [[ "$OWNER_NAME" == "headroom" ]]; then
        echo "Killing headroom process (PID $OWNER_PID) on port $HEADROOM_PORT..."
        kill "$OWNER_PID" 2>/dev/null || true
        sleep 1
        # Force kill if still alive
        if kill -0 "$OWNER_PID" 2>/dev/null; then
            kill -9 "$OWNER_PID" 2>/dev/null || true
        fi
    else
        echo "⚠ Port $HEADROOM_PORT is occupied by non-headroom process: $OWNER_NAME (PID $OWNER_PID)" >&2
        if [[ "$KILL_PORT_OWNER" == "true" ]]; then
            echo "  --kill-port-owner flag set. Killing $OWNER_NAME (PID $OWNER_PID)..."
            kill "$OWNER_PID" 2>/dev/null || true
            sleep 1
            if kill -0 "$OWNER_PID" 2>/dev/null; then
                kill -9 "$OWNER_PID" 2>/dev/null || true
            fi
        else
            echo "  Aborting. Re-run with --kill-port-owner to force-kill the blocking process." >&2
            exit 1
        fi
    fi
fi

# 3) Final check — port must be free
sleep 1
PORT_OWNER=$(get_port_owner "$HEADROOM_PORT")
if [[ -n "$PORT_OWNER" ]]; then
    echo "❌ Port $HEADROOM_PORT is still occupied. Cannot proceed." >&2
    exit 1
fi

echo "✓ Port $HEADROOM_PORT is free"

# --- Install / Upgrade -----------------------------------------------------
echo "Installing headroom-ai[all]==${LATEST_VERSION} via pipx..."
if ! retry_command pipx install "headroom-ai[all]==${LATEST_VERSION}" --force --pip-args="--ignore-requires-python"; then
    echo "❌ pipx install failed" >&2
    exit 1
fi

if ! command -v headroom >/dev/null 2>&1; then
    echo "❌ Installation finished, but 'headroom' is not on PATH." >&2
    exit 1
fi

echo "Syncing MCP configuration..."
headroom mcp install --force || {
    echo "⚠ headroom mcp install --force failed (non-fatal, continuing)" >&2
}

INSTALLED_VERSION_RAW=$(headroom --version 2>/dev/null || true)
INSTALLED_VERSION=$(extract_version "$INSTALLED_VERSION_RAW")
echo "Installed version: ${INSTALLED_VERSION_RAW:-unknown}"
if [[ -n "$INSTALLED_VERSION" && "$INSTALLED_VERSION" != "$LATEST_VERSION" ]]; then
    echo "❌ Installed version mismatch: expected $LATEST_VERSION, got $INSTALLED_VERSION" >&2
    exit 1
fi

# --- Restart proxy in background --------------------------------------------

if [[ -n "$PRIMARY_PROFILE" ]]; then
    echo "Restarting manifest profile '$PRIMARY_PROFILE' in background..."
    if ! headroom install start --profile "$PRIMARY_PROFILE" 2>/dev/null; then
        echo "❌ Failed to restart manifest profile '$PRIMARY_PROFILE'." >&2
        exit 1
    fi
else
    start_direct_proxy
fi

# --- Health check (12 × 5s = 60s max) -------------------------------------
echo "Waiting for proxy health on port $HEADROOM_PORT..."
HEALTH_URLS=(
    "$PRIMARY_HEALTH_URL"
    "http://${HEADROOM_HOST}:${HEADROOM_PORT}/health"
    "http://${HEADROOM_HOST}:${HEADROOM_PORT}/readyz"
    "http://localhost:${HEADROOM_PORT}/health"
    "http://localhost:${HEADROOM_PORT}/readyz"
)

if HEALTH_URL=$(wait_for_health "${HEALTH_URLS[@]}"); then
    echo "✓ Proxy is healthy ($HEALTH_URL)"
else
    echo "⚠ Proxy did not report healthy within 60s. Check logs at ${HOME}/.headroom/logs/" >&2
    exit 1
fi

echo "✓ Headroom update completed (${CURRENT_VERSION:-not installed} -> $LATEST_VERSION)"
