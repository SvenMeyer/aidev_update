#!/bin/bash
set -eo pipefail

# Headroom AI update script
# https://github.com/chopratejas/headroom/releases
#
# Usage:
#   ./headroom_update.sh                   # normal update to latest
#   ./headroom_update.sh --override-version X.Y.Z  # force install a specific version
#   ./headroom_update.sh --kill-port-owner          # allow killing non-headroom process on 8787

HEADROOM_PORT=8787
HEADROOM_REPO="chopratejas/headroom"
DEPLOY_ROOT="${HOME}/.headroom/deploy"

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
OVERRIDE_VERSION=""
KILL_PORT_OWNER=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --override-version)
            OVERRIDE_VERSION="$2"
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
        else
            echo "Attempt $attempt failed. Retrying..." >&2
            ((attempt++))
            sleep 2
        fi
    done
    echo "All attempts failed." >&2
    return 1
}

# Extract semver from version output (handles "headroom, version X.Y.Z")
extract_version() {
    echo "$1" | grep -oE '([0-9]+\.){2}[0-9]+(-[0-9A-Za-z.]+)?' | head -1 || true
}

# Get the latest release version from GitHub API (primary)
# Falls back to scraping the releases HTML page
get_latest_version() {
    local ver=""

    # Primary: GitHub API
    ver=$(curl -s "https://api.github.com/repos/${HEADROOM_REPO}/releases/latest" 2>/dev/null \
        | grep -o '"tag_name": "[^"]*' \
        | sed -E 's/"tag_name": "v?//' || true)

    if [[ -n "$ver" ]]; then
        echo "$ver"
        return 0
    fi

    # Fallback: scrape HTML releases page
    ver=$(curl -sL "https://github.com/${HEADROOM_REPO}/releases" 2>/dev/null \
        | grep -oE '/releases/tag/v?[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?' \
        | head -1 \
        | sed -E 's|.*/tag/v?||' || true)

    if [[ -n "$ver" ]]; then
        echo "$ver"
        return 0
    fi

    echo ""
    return 1
}

# Find deployment profiles that use HEADROOM_PORT
find_profiles_on_port() {
    local port="$1"
    local profiles=()
    if [[ -d "$DEPLOY_ROOT" ]]; then
        for manifest in "$DEPLOY_ROOT"/*/manifest.json; do
            [[ -f "$manifest" ]] || continue
            manifest_port=$(python3 -c "
import json, sys
with open('$manifest') as f:
    d = json.load(f)
print(d.get('port', ''))
" 2>/dev/null || true)
            if [[ "$manifest_port" == "$port" ]]; then
                profile_name=$(python3 -c "
import json
with open('$manifest') as f:
    d = json.load(f)
print(d.get('profile', ''))
" 2>/dev/null || true)
                [[ -n "$profile_name" ]] && profiles+=("$profile_name")
            fi
        done
    fi
    printf '%s\n' "${profiles[@]}"
}

# Get PID of the process listening on a given port (tcp, IPv4)
get_port_owner() {
    local port="$1"
    lsof -nP -iTCP:"${port}" -sTCP:LISTEN 2>/dev/null | awk 'NR>1 {print $1, $2; exit}' || true
}

# ---------------------------------------------------------------------------
# Main logic
# ---------------------------------------------------------------------------

echo "Headroom Update"

# Check dependencies
for cmd in pipx curl headroom; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "❌ '$cmd' is required but not installed." >&2
        exit 1
    fi
done

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
CURRENT_VERSION_RAW=$(headroom --version 2>/dev/null || true)
CURRENT_VERSION=$(extract_version "$CURRENT_VERSION_RAW")
echo "Current version: ${CURRENT_VERSION:-not installed}"

# --- Version comparison -----------------------------------------------------
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

echo "Update required: ${CURRENT_VERSION:-not installed} -> $LATEST_VERSION"

# --- Stop Headroom ----------------------------------------------------------

# 1) Try manifest-backed stop for each profile on the port
PROFILES=()
while IFS= read -r p; do
    [[ -n "$p" ]] && PROFILES+=("$p")
done < <(find_profiles_on_port "$HEADROOM_PORT")

if [[ ${#PROFILES[@]} -gt 1 ]]; then
    echo "⚠ Multiple deployment profiles on port $HEADROOM_PORT: ${PROFILES[*]}"
    echo "  Stopping all of them."
fi

for profile in "${PROFILES[@]}"; do
    echo "Stopping manifest profile '$profile'..."
    headroom install stop --profile "$profile" 2>/dev/null || true
done

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

echo "Syncing MCP configuration..."
headroom mcp install --force || {
    echo "⚠ headroom mcp install --force failed (non-fatal, continuing)" >&2
}

echo "Installed version: $(headroom --version 2>/dev/null || echo 'unknown')"

# --- Restart proxy in background --------------------------------------------

# Determine how to restart:
# - If we had exactly one profile, restart it via headroom install start
# - Otherwise, launch headroom proxy directly in the background
RESTART_PROFILE=""
if [[ ${#PROFILES[@]} -eq 1 ]]; then
    RESTART_PROFILE="${PROFILES[0]}"
fi

if [[ -n "$RESTART_PROFILE" ]]; then
    echo "Restarting manifest profile '$RESTART_PROFILE' in background..."
    headroom install start --profile "$RESTART_PROFILE" 2>/dev/null || {
        echo "⚠ headroom install start failed, falling back to direct proxy launch" >&2
        RESTART_PROFILE=""
    }
fi

if [[ -z "$RESTART_PROFILE" ]]; then
    LOG_DIR="${HOME}/.headroom/logs"
    mkdir -p "$LOG_DIR"
    LOG_FILE="$LOG_DIR/proxy.log"
    echo "Starting headroom proxy in background (log: $LOG_FILE)..."
    nohup headroom proxy >"$LOG_FILE" 2>&1 &
    PROXY_PID=$!
    echo "Proxy PID: $PROXY_PID"
fi

# --- Health check (12 × 5s = 60s max) -------------------------------------
echo "Waiting for proxy health on port $HEADROOM_PORT..."
HEALTH_OK=false
for i in $(seq 1 12); do
    RESPONSE=$(curl -s "http://localhost:${HEADROOM_PORT}/health" 2>/dev/null || true)
    if [[ -n "$RESPONSE" ]]; then
        STATUS=$(echo "$RESPONSE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('status',''))" 2>/dev/null || true)
        READY=$(echo "$RESPONSE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('ready',''))" 2>/dev/null || true)
        if [[ "$STATUS" == "healthy" ]] || [[ "$READY" == "True" ]] || [[ "$READY" == "true" ]]; then
            HEALTH_OK=true
            break
        fi
    fi
    sleep 5
done

if [[ "$HEALTH_OK" == "true" ]]; then
    echo "✓ Proxy is healthy (http://localhost:${HEADROOM_PORT}/health)"
else
    echo "⚠ Proxy did not report healthy within 60s. Check logs at ${HOME}/.headroom/logs/" >&2
    exit 1
fi

echo "✓ Headroom update completed ($CURRENT_VERSION -> $LATEST_VERSION)"
