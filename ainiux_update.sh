#!/usr/bin/env bash
# Install or update Ainiux (https://github.com/petrikuittinen/ainiux) from source.
# Pulls the clone, rebuilds and reinstalls into ~/.local only when something
# changed (or the binary is missing); clones first on a fresh machine.
# Prerequisites on Manjaro: base-devel pkgconf git sqlite curl zlib openssl.
# Override the clone location with AINIUX_SRC_DIR.
set -euo pipefail

AINIUX_REPO="https://github.com/petrikuittinen/ainiux.git"
AINIUX_SRC_DIR="${AINIUX_SRC_DIR:-$HOME/DEV/AI/ainiux}"
AINIUX_BIN="$HOME/.local/bin/ainiux"

echo "Ainiux Install / Update"

for dep in git make g++; do
    if ! command -v "$dep" >/dev/null 2>&1; then
        echo "Error: $dep is required. Install it with: sudo pacman -S --needed base-devel git" >&2
        exit 1
    fi
done

if [[ -x "$AINIUX_BIN" ]]; then
    printf 'Installed version: '
    "$AINIUX_BIN" --version
else
    echo "Installed version: not installed"
fi

if [[ ! -d "$AINIUX_SRC_DIR/.git" ]]; then
    echo "Cloning $AINIUX_REPO into $AINIUX_SRC_DIR..."
    mkdir -p "$(dirname "$AINIUX_SRC_DIR")"
    git clone "$AINIUX_REPO" "$AINIUX_SRC_DIR"
    before=""
else
    before="$(git -C "$AINIUX_SRC_DIR" rev-parse HEAD)"
    echo "Pulling latest sources..."
    git -C "$AINIUX_SRC_DIR" pull --ff-only
fi
after="$(git -C "$AINIUX_SRC_DIR" rev-parse HEAD)"

if [[ "$before" == "$after" && -x "$AINIUX_BIN" ]]; then
    echo "Already up to date ($(git -C "$AINIUX_SRC_DIR" rev-parse --short HEAD))."
    exit 0
fi

echo "Building and installing into ~/.local..."
# Run as the normal user from the clone; the installer verifies PATH resolution.
(cd "$AINIUX_SRC_DIR" && ./scripts/install.sh --user)

if [[ ! -x "$AINIUX_BIN" ]]; then
    echo "Error: ainiux executable missing after installation: $AINIUX_BIN" >&2
    exit 1
fi

printf 'Updated version: '
"$AINIUX_BIN" --version
echo "Ainiux installation / update completed successfully."
