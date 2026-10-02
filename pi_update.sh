#!/usr/bin/env bash
# Update the Pi coding agent via its own update command; install it first on
# a fresh machine.
# (The old npm-based updater pinned the retired @mariozechner scope and
# reinstalled the deprecated 0.73.x line; `pi update` handles the move to
# @earendil-works/pi-coding-agent correctly.)
if command -v pi >/dev/null 2>&1; then
    exec pi update
fi
echo "pi not found — installing the latest version…"
exec npm install -g @earendil-works/pi-coding-agent
