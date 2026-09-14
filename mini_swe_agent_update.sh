#!/bin/bash
set -euo pipefail

# mini-swe-agent install/update script
# https://pypi.org/project/mini-swe-agent/
#
# Installs on the first run, updates on later runs, and does nothing when the
# latest release is already installed.
#
# Usage:
#   ./mini_swe_agent_update.sh                  # install or update to the latest release
#   ./mini_swe_agent_update.sh --force          # reinstall even if already up to date
#   ./mini_swe_agent_update.sh --version X.Y.Z  # install a specific release

PACKAGE="mini-swe-agent"
VERIFY_APP="mini"
PYPI_JSON_URL="https://pypi.org/pypi/${PACKAGE}/json"

FORCE=false
PINNED_VERSION=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --force|-f)
            FORCE=true
            shift
            ;;
        --version)
            if [[ $# -lt 2 || -z "${2:-}" || "${2:-}" == --* ]]; then
                echo "Missing value for --version" >&2
                exit 1
            fi
            PINNED_VERSION="${2#v}"
            if [[ ! "$PINNED_VERSION" =~ ^[0-9]+(\.[0-9]+)*([A-Za-z0-9.+-]*)$ ]]; then
                echo "Invalid version: $2" >&2
                exit 1
            fi
            shift 2
            ;;
        -h|--help)
            sed -n '3,13p' "$0"
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            exit 1
            ;;
    esac
done

echo "mini-swe-agent Update Script"

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
if ! command -v pipx >/dev/null 2>&1; then
    echo "❌ pipx not found. Install it with: sudo pacman -S python-pipx" >&2
    exit 1
fi

for tool in curl python3; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "❌ $tool not found — required to query the PyPI release index." >&2
        exit 1
    fi
done

PIPX_HOME_DIR="$(pipx environment --value PIPX_HOME)"
PIPX_BIN_DIR="$(pipx environment --value PIPX_BIN_DIR)"
VENV_DIR="${PIPX_HOME_DIR}/venvs/${PACKAGE}"

case ":$PATH:" in
    *":${PIPX_BIN_DIR}:"*) ;;
    *) echo "⚠ ${PIPX_BIN_DIR} is not on your PATH — run 'pipx ensurepath' to fix" ;;
esac

# uv >= 0.12 refuses to build a venv over an existing directory and pipx
# installs into the existing venv rather than recreating it, so a stale
# directory would break the install. We always move the old venv aside first
# (see below), but keep this as a safety net for venvs outside PIPX_HOME.
export UV_VENV_CLEAR=1

# ---------------------------------------------------------------------------
# Current state / latest release
# ---------------------------------------------------------------------------
# Emits two lines: installed version, then the spec it was installed from.
read_installed() {
    pipx list --json 2>/dev/null | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
venv = data.get("venvs", {}).get(sys.argv[1])
if not venv:
    sys.exit(0)
pkg = venv["metadata"]["main_package"]
print(pkg.get("package_version") or "")
print(pkg.get("package_or_url") or "")
' "$PACKAGE"
}

INSTALLED_VERSION=""
INSTALLED_SOURCE=""
{ read -r INSTALLED_VERSION || true; read -r INSTALLED_SOURCE || true; } < <(read_installed)

if [[ -n "$INSTALLED_VERSION" ]]; then
    echo "Installed version   : $INSTALLED_VERSION"
else
    echo "Installed version   : not installed"
fi

if [[ -n "$PINNED_VERSION" ]]; then
    TARGET_VERSION="$PINNED_VERSION"
else
    TARGET_VERSION="$(curl -fsSL --max-time 30 "$PYPI_JSON_URL" 2>/dev/null | python3 -c '
import json, sys
try:
    print(json.load(sys.stdin)["info"]["version"])
except Exception:
    pass
' || true)"

    if [[ -z "$TARGET_VERSION" ]]; then
        # Offline or PyPI unreachable: keep a working install rather than
        # tearing it down for an update we cannot complete.
        if [[ -n "$INSTALLED_VERSION" ]]; then
            echo "⚠ Could not reach PyPI — keeping the installed version."
            exit 0
        fi
        echo "❌ Could not reach PyPI to determine the latest version." >&2
        exit 1
    fi
fi

echo "Latest version      : $TARGET_VERSION"

# A previous install from a git URL must be replaced even when the version
# string matches, so the switch to PyPI releases actually takes effect.
FROM_PYPI=true
if [[ "$INSTALLED_SOURCE" == *"://"* || "$INSTALLED_SOURCE" == git+* ]]; then
    FROM_PYPI=false
fi

if [[ -n "$INSTALLED_VERSION" && "$INSTALLED_VERSION" == "$TARGET_VERSION" \
      && "$FORCE" == false && "$FROM_PYPI" == true ]]; then
    echo "✓ Already up to date!"
    exit 0
fi

# ---------------------------------------------------------------------------
# Install, keeping the previous venv until the new one is proven good
# ---------------------------------------------------------------------------
BACKUP_DIR=""
INSTALL_OK=false

cleanup() {
    [[ -n "$BACKUP_DIR" && -d "$BACKUP_DIR" ]] || return 0

    if [[ "$INSTALL_OK" == true ]]; then
        rm -rf "$BACKUP_DIR"
        return 0
    fi

    # Restoring to the original path also revives the app symlinks in
    # PIPX_BIN_DIR, which point into the venv and are left untouched by a
    # failed pipx install.
    echo "↩ Restoring the previous installation..."
    rm -rf "$VENV_DIR"
    if mv "$BACKUP_DIR/venv" "$VENV_DIR" 2>/dev/null; then
        echo "✓ Previous version restored ($INSTALLED_VERSION)"
    else
        echo "❌ Could not restore the previous venv from $BACKUP_DIR" >&2
    fi
    rm -rf "$BACKUP_DIR"
}
trap cleanup EXIT INT TERM

if [[ -d "$VENV_DIR" ]]; then
    # A rename is instant and keeps the old venv intact, so a failed download
    # or build can be rolled back instead of leaving nothing installed.
    BACKUP_DIR="$(mktemp -d "${PIPX_HOME_DIR}/.${PACKAGE}-backup.XXXXXX")"
    mv "$VENV_DIR" "$BACKUP_DIR/venv"
fi

echo "Installing ${PACKAGE}==${TARGET_VERSION} ..."
if ! pipx install "${PACKAGE}==${TARGET_VERSION}"; then
    echo "❌ mini-swe-agent installation failed!" >&2
    exit 1
fi

# --help (not --version, which 'mini' does not accept) exercises the entry
# point far enough to catch a broken venv or missing dependency.
if ! "${PIPX_BIN_DIR}/${VERIFY_APP}" --help >/dev/null 2>&1; then
    echo "❌ '${VERIFY_APP}' is not runnable after install!" >&2
    exit 1
fi

INSTALL_OK=true

read -r NEW_VERSION < <(read_installed) || true
echo "Updated version     : ${NEW_VERSION:-$TARGET_VERSION}"
echo "✓ mini-swe-agent update completed successfully!"
