#!/usr/bin/env bash
# Update nvm, then every Node line installed under nvm to its latest release,
# carrying over global npm packages and the newest npm. Old patch versions of
# a line are removed once the new one is in. aidev_update.sh runs this first,
# so the tool updaters after it see the fresh node/npm.
#
# npm 12 blocks install scripts by default, which leaves native-binary CLIs
# (claude, opencode, ...) unusable after any `npm install -g`. This script adds
# ALLOW_SCRIPTS to `allow-scripts` in the user ~/.npmrc, so every later global
# install — by the other updaters or by hand — runs them. Entries already in
# ~/.npmrc are kept. AIDEV_NODE_ALLOW_SCRIPTS replaces the list below.
NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
ALLOW_SCRIPTS="${AIDEV_NODE_ALLOW_SCRIPTS:-@anthropic-ai/claude-code,opencode-ai,@kilocode/cli,@minimax-ai/code,codebuff,@just-every/code,@github/keytar,node-pty,better-sqlite3,esbuild,bufferutil,tree-sitter-bash,protobufjs,@lvce-editor/ripgrep,tldjs}"

# Merge ALLOW_SCRIPTS into the user config's allow-scripts (no-op when covered).
ensure_allow_scripts() {
    local have merged
    have=$(npm config get allow-scripts --location=user 2>/dev/null)
    merged=$(printf '%s\n' ${have//,/ } ${ALLOW_SCRIPTS//,/ } | awk 'NF && !seen[$0]++' | paste -sd,)
    [ "$merged" = "$have" ] && return 0
    npm config set "allow-scripts=$merged" --location=user && echo "npm allow-scripts updated in ~/.npmrc"
}

# --- 1. nvm itself -----------------------------------------------------------
# nvm is a git clone; the official installer fast-forwards it to a release tag.
# PROFILE=/dev/null keeps the installer away from the shell rc files.
latest_nvm_tag() {
    gh api repos/nvm-sh/nvm/releases/latest --jq .tag_name 2>/dev/null \
        || curl -fsSL https://api.github.com/repos/nvm-sh/nvm/releases/latest \
           | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p'
}

if [ ! -s "$NVM_DIR/nvm.sh" ]; then
    tag=$(latest_nvm_tag)
    [ -n "$tag" ] || { echo "nvm not found and the latest release is unknown" >&2; exit 1; }
    echo "nvm not found — installing $tag…"
    curl -fsSL "https://raw.githubusercontent.com/nvm-sh/nvm/$tag/install.sh" \
        | PROFILE=/dev/null bash || exit 1
else
    . "$NVM_DIR/nvm.sh"
    current="v$(nvm --version)"
    tag=$(latest_nvm_tag)
    if [ -z "$tag" ]; then
        echo "⚠ could not look up the latest nvm release — leaving nvm at $current" >&2
    elif [ "$tag" = "$current" ]; then
        echo "nvm $current is up to date."
    else
        echo "nvm $current → $tag"
        curl -fsSL "https://raw.githubusercontent.com/nvm-sh/nvm/$tag/install.sh" \
            | PROFILE=/dev/null bash || exit 1
    fi
fi
. "$NVM_DIR/nvm.sh"

# --- 2. Node: latest release of every installed line --------------------------
# Lines come from what is installed (v24.x.y → 24); nothing new is added.
mapfile -t LINES < <(ls -1 "$NVM_DIR/versions/node" 2>/dev/null \
    | grep -oE '^v[0-9]+' | sort -uV)
if [ "${#LINES[@]}" -eq 0 ]; then
    echo "No nvm-managed Node found — installing the latest LTS…"
    npm_config_allow_scripts="$ALLOW_SCRIPTS" nvm install --lts --latest-npm || exit 1
    nvm alias default 'lts/*' >/dev/null
    ensure_allow_scripts
    exit 0
fi
ensure_allow_scripts

# Drop every older patch of a line (default pinned to one moves to the newest first).
prune_line() {
    local line=$1 keep=$2 v pinned
    nvm use --silent "$keep" >/dev/null 2>&1   # nvm refuses to remove the active version
    for v in $(ls -1 "$NVM_DIR/versions/node" | grep -E "^$line\\."); do
        [ "$v" = "$keep" ] && continue
        pinned=$(cat "$NVM_DIR/alias/default" 2>/dev/null)
        if [[ "$pinned" =~ ^v?[0-9][0-9.]*$ ]] && [ "$(nvm version "$pinned")" = "$v" ]; then
            nvm alias default "$keep" >/dev/null
        fi
        nvm uninstall "$v" >/dev/null 2>&1 && echo "removed node $v"
    done
}

failed=0
for line in "${LINES[@]}"; do
    new=$(nvm version-remote "$line" 2>/dev/null)
    old=$(nvm version "$line" 2>/dev/null)
    if [ -z "$new" ] || [ "$new" = "N/A" ]; then
        echo "⚠ $line: could not look up the latest release" >&2; failed=1; continue
    fi
    if [ "$new" = "$old" ]; then
        echo "node $old is up to date."
    else
        echo "node $old → $new"
        if ! nvm install "$new" --reinstall-packages-from="$old" --latest-npm; then
            echo "✗ node $new install failed — keeping $old" >&2
            failed=1
            continue
        fi
    fi
    prune_line "$line" "$new"
done

exit "$failed"
