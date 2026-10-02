#!/usr/bin/env bash
# Update the Pi coding agent via its own update command.
# (The old npm-based updater pinned the retired @mariozechner scope and
# reinstalled the deprecated 0.73.x line; `pi update` handles the move to
# @earendil-works/pi-coding-agent correctly.)
exec pi update
