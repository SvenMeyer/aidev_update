#!/usr/bin/env bash
#
# aidev_update.sh (v2.0.0) — pick tools, run their *_update.sh one after the other.
#
# Every *_update.sh next to this script is one tool. An interactive run opens
# a checkbox menu first; the choice is saved to selection.md and reused next
# time. A non-interactive run (pipe, cron) uses the saved selection silently.
#
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$(basename "${BASH_SOURCE[0]}")"      # our own name matches *_update.sh
SELECTION_FILE="$SCRIPT_DIR/selection.md"
STEP_TIMEOUT="${AIDEV_STEP_TIMEOUT:-600}"   # per-tool hang cap; env override is a test knob

[ $# -eq 0 ] || echo "note: no options — tools are picked in the menu or in $SELECTION_FILE" >&2

# --- 1. Discover tools: the directory is the tool list ----------------------
mapfile -t TOOLS < <(cd "$SCRIPT_DIR" && ls -1 -- *_update.sh 2>/dev/null \
                     | sort | grep -vxF -- "$SELF")
if [ "${#TOOLS[@]}" -eq 0 ]; then
    echo "No *_update.sh scripts found in $SCRIPT_DIR" >&2
    exit 0
fi

# --- 2. Selection state: ON[i]=1 runs, 0 skips ------------------------------
# selection.md format: "- [x] tool_update.sh" / "- [ ] tool_update.sh".
# A tool missing from the file defaults to on (new scripts auto-join).
# Stale lines naming deleted scripts are ignored; the menu rewrites the file.
ON=()
load_selection() {
    local i line mark name
    for i in "${!TOOLS[@]}"; do ON[i]=1; done
    [ -f "$SELECTION_FILE" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"
        if [[ "$line" =~ ^-[[:space:]]*\[[[:space:]xX]\][[:space:]]*(.+)$ ]]; then
            mark="${line%%]*}"; mark="${mark: -1}"
            name="${BASH_REMATCH[1]}"
            for i in "${!TOOLS[@]}"; do
                if [ "${TOOLS[i]}" = "$name" ]; then
                    if [ "$mark" = " " ]; then ON[i]=0; else ON[i]=1; fi
                fi
            done
        fi
    done < "$SELECTION_FILE"
}

save_selection() {
    local i tmp
    tmp=$(mktemp "$SELECTION_FILE.XXXXXX") || return 1
    {
        echo "# Tools to update — written by aidev_update.sh, safe to edit by hand."
        echo "# [x] runs, [ ] does not. Tools missing here default to on."
        for i in "${!TOOLS[@]}"; do
            if [ "${ON[i]}" -eq 1 ]; then echo "- [x] ${TOOLS[i]}"; else echo "- [ ] ${TOOLS[i]}"; fi
        done
    } > "$tmp" && mv -f "$tmp" "$SELECTION_FILE"
}

# --- 3. Menu: ↑/↓ move, space toggles, enter runs, q/Esc cancels ------------
cursor=0
selected_count() {
    local i n=0
    for i in "${!ON[@]}"; do [ "${ON[i]}" -eq 1 ] && n=$((n + 1)); done
    printf '%s' "$n"
}

draw_menu() {
    local i mark arrow
    echo "aidev update — ↑/↓ move, space toggles, enter runs, q quits"
    for i in "${!TOOLS[@]}"; do
        [ "${ON[i]}" -eq 1 ] && mark="x" || mark=" "
        [ "$i" -eq "$cursor" ] && arrow=">" || arrow=" "
        printf '%s [%s] %s\n' "$arrow" "$mark" "${TOOLS[i]%_update.sh}"
    done
    echo "  $(selected_count)/${#TOOLS[@]} selected"
}

# Returns 0 = run (enter), 1 = cancelled (q, Esc, Ctrl-D).
menu_loop() {
    local key seq
    draw_menu
    while true; do
        IFS= read -rsn1 key || return 1
        if [[ "$key" == $'\x1b' ]]; then
            seq=""
            IFS= read -rsn2 -t 0.05 seq || true
            if [[ "$seq" == "[A" || "$seq" == "OA" ]]; then
                [ "$cursor" -gt 0 ] && cursor=$((cursor - 1))
            elif [[ "$seq" == "[B" || "$seq" == "OB" ]]; then
                [ "$cursor" -lt $((${#TOOLS[@]} - 1)) ] && cursor=$((cursor + 1))
            else
                return 1
            fi
        elif [[ "$key" == " " ]]; then
            if [ "${ON[cursor]}" -eq 1 ]; then ON[cursor]=0; else ON[cursor]=1; fi
        elif [[ -z "$key" ]]; then
            return 0
        elif [[ "$key" == "q" ]]; then
            return 1
        else
            continue
        fi
        printf '\033[%dA\033[J' "$((${#TOOLS[@]} + 2))"
        draw_menu
    done
}

# --- 4. Run the selected tools one after the other --------------------------
run_selected() {
    local i name selected=0 failed=0
    local -a failures=()
    for i in "${!TOOLS[@]}"; do
        [ "${ON[i]}" -eq 1 ] || continue
        selected=$((selected + 1))
        name="${TOOLS[i]%_update.sh}"
        echo ""
        echo "=== $name ==="
        if command -v timeout >/dev/null 2>&1; then
            timeout --kill-after=10 "$STEP_TIMEOUT" bash "$SCRIPT_DIR/${TOOLS[i]}"
        else
            bash "$SCRIPT_DIR/${TOOLS[i]}"
        fi
        if [ $? -eq 0 ]; then
            echo "✓ $name"
        else
            echo "✗ $name"
            failed=$((failed + 1))
            failures+=("$name")
        fi
    done
    echo ""
    if [ "$selected" -eq 0 ]; then
        echo "Nothing selected — nothing to update."
        return 0
    fi
    if [ "$failed" -gt 0 ]; then
        echo "$((selected - failed))/$selected tools updated; failed: ${failures[*]}"
        return 1
    fi
    echo "$selected/$selected tools updated."
    return 0
}

# --- 5. Main -----------------------------------------------------------------
load_selection
if { [ -t 0 ] && [ -t 1 ]; } || [ "${AIDEV_MENU_FORCE:-0}" = "1" ]; then
    if menu_loop; then
        save_selection || echo "⚠ could not write $SELECTION_FILE (running anyway)" >&2
        printf '\033[H\033[2J'
    else
        echo ""
        echo "Cancelled — saved selection unchanged."
        exit 0
    fi
fi
run_selected
exit $?
