#!/usr/bin/env bash
# Keep the Pi coding agent on pi.dev's *managed* installation (dependencies
# pinned by a lockfile Pi publishes, installed with `npm ci --ignore-scripts`)
# instead of `npm install -g`, which re-resolves every transitive dependency.
#
#   pi missing                    -> official installer (fresh install)
#   npm-global pi (legacy)        -> official installer (migrates to managed)
#   managed pi                    -> `pi update --all` (pi + extensions)
#
# The installer is only run when there is something to install or migrate, so
# its "reinstall" / "uninstall" actions are never reached from here. On a first
# run it may ask questions (Enter accepts the default; do not press `u`, which
# uninstalls). "Start pi now?" is suppressed by keeping its stdout off a tty.
# Node >= 22.19 is required; when missing, node_update.sh (nvm + latest LTS)
# provides it first.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PI_PKG="@earendil-works/pi-coding-agent"
PI_INSTALLER_URL="https://pi.dev/install.sh"
NVM_DIR="${NVM_DIR:-$HOME/.nvm}"

# True when node is present and >= 22.19.0.
node_ok() {
    command -v node >/dev/null 2>&1 && node -e '
        const [a, b] = process.versions.node.split(".").map(Number);
        process.exit(a > 22 || (a === 22 && b >= 19) ? 0 : 1)'
}

# True when Pi is installed as an npm global package (the legacy layout).
legacy_npm_pi() {
    command -v npm >/dev/null 2>&1 || return 1
    [ -d "$(npm root -g 2>/dev/null)/$PI_PKG" ]
}

if ! node_ok; then
    echo "Node.js 22.19+ not found — setting it up with nvm (node_update.sh)…"
    bash "$SCRIPT_DIR/node_update.sh" || exit 1
    # shellcheck disable=SC1091
    . "$NVM_DIR/nvm.sh" --no-use && nvm use --silent default >/dev/null 2>&1 \
        || nvm use --silent node >/dev/null 2>&1
    node_ok || { echo "✗ no usable Node.js 22.19+ after node_update.sh" >&2; exit 1; }
fi

if command -v pi >/dev/null 2>&1 && ! legacy_npm_pi; then
    exec pi update --all
fi

if command -v pi >/dev/null 2>&1; then
    echo "pi is an npm-global install — migrating to the managed installation…"
else
    echo "pi not found — installing the managed version…"
fi

installer=$(mktemp "${TMPDIR:-/tmp}/pi-install.XXXXXX") || exit 1
trap 'rm -f "$installer"' EXIT
curl -fsSL "$PI_INSTALLER_URL" -o "$installer" || { echo "✗ could not download $PI_INSTALLER_URL" >&2; exit 1; }

# `| cat` keeps stdout off a tty, which makes the installer skip "Start pi now?".
# Its other prompts talk to /dev/tty directly and still work.
set -o pipefail
sh "$installer" | cat || exit 1

command -v pi >/dev/null 2>&1 || hash -r
if ! command -v pi >/dev/null 2>&1; then
    echo "⚠ pi was installed but is not on PATH yet — open a new shell (or add the bin dir the installer printed)." >&2
fi
