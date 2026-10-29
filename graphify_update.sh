#!/bin/bash
set -euo pipefail

# Install or update the official Graphify CLI on Manjaro Linux.
# https://github.com/Graphify-Labs/graphify
# Usage: bash graphify_update.sh
# Prerequisite: uv (on Manjaro: sudo pacman -S uv).
# The official PyPI package is graphifyy (double-y); the CLI is graphify.

echo "Graphify Install / Update"

if ! command -v uv >/dev/null 2>&1; then
    echo "Error: uv is required. Install it with: sudo pacman -S uv" >&2
    exit 1
fi

if command -v graphify >/dev/null 2>&1; then
    printf 'Installed version: '
    graphify --version
else
    echo "Installed version: not installed"
fi

# Handles both a first install and an existing uv-managed installation.
# Refresh the index so a recently published stable release is discovered.
echo "Installing the latest stable graphifyy package via uv..."
uv tool install --upgrade --refresh graphifyy

# Resolve uv's own binary directory, including when it is not yet on PATH.
GRAPHIFY_BIN="$(uv tool dir --bin)/graphify"
if [[ ! -x "$GRAPHIFY_BIN" ]]; then
    echo "Error: graphify executable missing after installation: $GRAPHIFY_BIN" >&2
    exit 1
fi

printf 'Updated version: '
"$GRAPHIFY_BIN" --version 2>/dev/null

# --- Refresh the skill copies of every coding CLI ---------------------------
# A package upgrade leaves the installed skills (~/.claude, ~/.codex,
# ~/.pi/agent, ...) at the old version. graphify refreshes them itself, but
# only on a "real" command, never on --version. Run that same refresh now: it
# re-copies only skills graphify installed whose stamp is older than the
# package, keeps a locally edited SKILL.md as SKILL.md.bak, and installs
# nothing new. GRAPHIFY_NO_AUTO_REFRESH=1 opts out (graphify's own switch).
GRAPHIFY_PY="$(uv tool dir)/graphifyy/bin/python"
echo "Refreshing graphify skills of the installed coding CLIs..."
if ! "$GRAPHIFY_PY" -c 'from graphify.__main__ import _refresh_stale_skills as r; r()' 2>&1; then
    # Fallback if graphify drops that internal function: run the command each
    # stale-skill warning names ("graphify install --platform X").
    echo "built-in refresh unavailable — following graphify's warnings instead"
    for p in $("$GRAPHIFY_BIN" --version 2>&1 >/dev/null \
               | sed -n "s/.*Run 'graphify install --platform \([a-z-]*\)'.*/\1/p" | sort -u); do
        echo "  graphify install --platform $p"
        (cd "$HOME" && "$GRAPHIFY_BIN" install --platform "$p" >/dev/null) \
            || echo "  ⚠ graphify install --platform $p failed" >&2
    done
fi

# Whatever graphify still warns about could not be refreshed automatically
# (e.g. a skill newer than the package, or a directory shared by two CLIs).
remaining=$("$GRAPHIFY_BIN" --version 2>&1 >/dev/null || true)
if [[ -n "$remaining" ]]; then
    echo "⚠ graphify skills still needing attention:"
    echo "$remaining"
else
    echo "All graphify skills match the package."
fi
echo "Graphify installation / update completed successfully."
