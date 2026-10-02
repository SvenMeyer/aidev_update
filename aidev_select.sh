#!/bin/bash
#
# aidev_select.sh - choose which tools aidev_update.sh updates.
#
# Called by aidev_update.sh before a run when a terminal is attached. The
# choice is written to the selection file (steps.conf, or AIDEV_STEPS_FILE)
# so the next run opens with the same tools switched on.
#
# Catalog lines (one per known tool):
#   +|kind|target|description    on in the built-in defaults
#   -|kind|target|description    off in the built-in defaults
#
# Selection file:
#   # aidev-selection-v1
#   kind|target|description              enabled, and therefore run
#   # disabled: kind|target|description  kept in the menu, not run
#
# A steps.conf written by hand, without the marker, still means what it
# means to the orchestrator: listed lines run, and every other known tool
# is off. Confirming the menu rewrites that file in the marker format.

set -u
set -o pipefail

if [ -z "${BASH_VERSINFO:-}" ] || \
   [ "${BASH_VERSINFO[0]}" -lt 4 ] || \
   { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -lt 4 ]; }; then
    echo "❌ aidev_select.sh requires bash >= 4.4 (found: ${BASH_VERSION:-unknown})." >&2
    exit 1
fi

CATALOG_FILE=""
SELECTION_FILE=""
FORCE=0

# Parallel arrays. cat_* is the built-in catalogue, file_* is the saved
# selection, items_* is what the menu shows and what gets written back.
cat_entries=()
cat_on=()
file_entries=()
file_on=()
items_entry=()
items_on=()
HAVE_FILE=0
HAVE_MARKER=0
FILE_INDEX=-1
MENU_WARNINGS=()

usage() {
    cat <<'EOF'
aidev_select.sh - choose which AI dev tools get updated

Usage: aidev_select.sh --catalog FILE --selection FILE [--force]

  --catalog FILE     Built-in tool list. Each line is
                     +|kind|target|description (default on) or
                     -|kind|target|description (default off).
  --selection FILE   Where the choice is stored. Created on confirm.
                     Usually steps.conf next to aidev_update.sh.
  --force            Open the menu even when stdin or stdout is not a
                     terminal. Used by tests.

Type a command at the prompt:
  a, all, select all      select ALL
  n, none, select none    select NONE
  3                       toggle tool 3
  3 5 9                   toggle several
  +3 -5                   turn 3 on and 5 off
  4-7                     toggle a range
  enter                   save and continue
  q                       quit without saving

Exit codes:
  0  selection saved
  1  the selection file could not be written
  2  quit, or invalid usage
EOF
}

trim_line() {
    local s="$1"
    s="${s%$'\r'}"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

# Identity of a step is kind|target. The description may change between
# releases; the saved on/off state still applies.
entry_key() {
    local kind target rest
    IFS='|' read -r kind target rest <<< "$1"
    printf '%s|%s' "$kind" "$target"
}

valid_entry() {
    local kind target description
    IFS='|' read -r kind target description <<< "$1"
    [ -n "$kind" ] && [ -n "$target" ] && [ -n "${description:-}" ]
}

warn() {
    MENU_WARNINGS+=("$1")
}

file_index_of() {
    local want="$1" i key
    FILE_INDEX=-1
    if [ "${#file_entries[@]}" -eq 0 ]; then
        return 1
    fi
    for i in "${!file_entries[@]}"; do
        key=$(entry_key "${file_entries[$i]}")
        if [ "$key" = "$want" ]; then
            FILE_INDEX=$i
            return 0
        fi
    done
    return 1
}

remember_file_entry() {
    local state="$1" entry="$2" key
    key=$(entry_key "$entry")
    if file_index_of "$key"; then
        file_on[FILE_INDEX]=$state
        file_entries[FILE_INDEX]=$entry
    else
        file_entries+=("$entry")
        file_on+=("$state")
    fi
}

load_catalog() {
    local line state entry key i dup
    local lineno=0

    while IFS= read -r line || [ -n "$line" ]; do
        lineno=$((lineno + 1))
        line=$(trim_line "$line")
        [ -z "$line" ] && continue
        [ "${line:0:1}" = "#" ] && continue

        if [[ "$line" == "+|"* ]]; then
            state=1
            entry="${line:2}"
        elif [[ "$line" == "-|"* ]]; then
            state=0
            entry="${line:2}"
        else
            warn "⚠ Ignoring catalog line $lineno (expected +|kind|target|description)."
            continue
        fi
        if ! valid_entry "$entry"; then
            warn "⚠ Ignoring catalog line $lineno (expected +|kind|target|description)."
            continue
        fi
        key=$(entry_key "$entry")
        dup=0
        for i in "${!cat_entries[@]}"; do
            if [ "$(entry_key "${cat_entries[$i]}")" = "$key" ]; then
                dup=1
                break
            fi
        done
        [ "$dup" -eq 1 ] && continue
        cat_entries+=("$entry")
        cat_on+=("$state")
    done < "$CATALOG_FILE"
}

load_selection() {
    local line rest kind target description entry key
    local lineno=0

    [ -f "$SELECTION_FILE" ] || return 0
    HAVE_FILE=1

    while IFS= read -r line || [ -n "$line" ]; do
        lineno=$((lineno + 1))
        line=$(trim_line "$line")
        [ -z "$line" ] && continue

        if [[ "$line" =~ ^#[[:space:]]*aidev-selection-v1[[:space:]]*$ ]]; then
            HAVE_MARKER=1
            continue
        fi
        if [[ "$line" =~ ^#[[:space:]]*disabled:[[:space:]]*(.*)$ ]]; then
            rest=$(trim_line "${BASH_REMATCH[1]}")
            if ! valid_entry "$rest"; then
                warn "⚠ Ignoring malformed disabled step at $SELECTION_FILE:$lineno."
                continue
            fi
            remember_file_entry 0 "$rest"
            continue
        fi
        [ "${line:0:1}" = "#" ] && continue

        if ! valid_entry "$line"; then
            warn "⚠ Ignoring malformed step at $SELECTION_FILE:$lineno."
            continue
        fi
        # Normalize so a hand-edited line and a catalogue line share a key
        # even when spacing around the description differs. Fields themselves
        # are kept as written, except we rebuild from the three fields so a
        # trailing comment cannot stick to the description.
        IFS='|' read -r kind target description <<< "$line"
        entry="$kind|$target|$description"
        remember_file_entry 1 "$entry"
    done < "$SELECTION_FILE"

    # An empty legacy file is not a choice of "update nothing". The
    # orchestrator ignores it and uses the built-in list; the menu does too.
    if [ "$HAVE_MARKER" -eq 0 ] && [ "${#file_entries[@]}" -eq 0 ]; then
        HAVE_FILE=0
    fi
}

build_items() {
    local i key on
    local -a used=()

    items_entry=()
    items_on=()
    if [ "${#file_entries[@]}" -gt 0 ]; then
        for i in "${!file_entries[@]}"; do
            used[i]=0
        done
    fi

    for i in "${!cat_entries[@]}"; do
        key=$(entry_key "${cat_entries[$i]}")
        if [ "$HAVE_FILE" -eq 0 ]; then
            on="${cat_on[$i]}"
        elif file_index_of "$key"; then
            on="${file_on[$FILE_INDEX]}"
            used[FILE_INDEX]=1
        elif [ "$HAVE_MARKER" -eq 1 ]; then
            # A tool added to the script after the last save keeps its
            # built-in default until the user confirms the menu.
            on="${cat_on[$i]}"
        else
            # A legacy steps.conf names the tools that run. Anything it
            # does not name stays off.
            on=0
        fi
        items_entry+=("${cat_entries[$i]}")
        items_on+=("$on")
    done

    # Tools that are in the file and not in the catalogue (a hand-added
    # line, or a tool removed from the script) stay in the menu.
    if [ "${#file_entries[@]}" -gt 0 ]; then
        for i in "${!file_entries[@]}"; do
            [ "${used[$i]:-0}" -eq 1 ] && continue
            items_entry+=("${file_entries[$i]}")
            items_on+=("${file_on[$i]}")
        done
    fi
}

draw_menu() {
    local i mark target description rest shown=0 total entry note
    total=${#items_entry[@]}

    if [ -t 1 ]; then
        printf '\033[H\033[2J'
    fi

    if [ ${#MENU_WARNINGS[@]} -gt 0 ]; then
        printf '%s\n' "${MENU_WARNINGS[@]}"
        echo ""
    fi

    echo "Select the tools to update. The choice is saved and reused next time."
    echo "Selection file: $SELECTION_FILE"
    if [ "$HAVE_FILE" -eq 0 ]; then
        note="Starting point: built-in defaults (nothing saved yet)."
    elif [ "$HAVE_MARKER" -eq 1 ]; then
        note="Starting point: saved selection."
    else
        note="Starting point: existing steps.conf (listed tools are on)."
    fi
    echo "$note"
    echo ""

    for i in "${!items_entry[@]}"; do
        if [ "${items_on[$i]}" -eq 1 ]; then
            mark="x"
            shown=$((shown + 1))
        else
            mark=" "
        fi
        entry="${items_entry[$i]}"
        rest="${entry#*|}"
        target="${rest%%|*}"
        description="${rest#*|}"
        printf '  %2d [%s] %s (%s)\n' "$((i + 1))" "$mark" "$description" "$target"
    done

    echo ""
    echo "$shown of $total selected."
    echo ""
    echo "  a  select ALL"
    echo "  n  select NONE"
    echo "  3  toggle 3     (also: 3 5 9, +3 -5, 4-7)"
    echo "  enter  save and continue"
    echo "  q  quit without saving"
    echo ""
}

set_all() {
    local state="$1" i
    for i in "${!items_on[@]}"; do
        items_on[i]=$state
    done
}

set_index() {
    local n state="$2" i
    n=$((10#$1))
    if [ "$n" -lt 1 ] || [ "$n" -gt ${#items_entry[@]} ]; then
        echo "No tool numbered $n." >&2
        return 1
    fi
    i=$((n - 1))
    items_on[i]=$state
}

toggle_index() {
    local n i
    n=$((10#$1))
    if [ "$n" -lt 1 ] || [ "$n" -gt ${#items_entry[@]} ]; then
        echo "No tool numbered $n." >&2
        return 1
    fi
    i=$((n - 1))
    if [ "${items_on[$i]}" -eq 1 ]; then
        items_on[i]=0
    else
        items_on[i]=1
    fi
}

apply_token() {
    local token="$1" start end n
    if [[ "$token" =~ ^[0-9]+$ ]]; then
        toggle_index "$token"
    elif [[ "$token" =~ ^\+([0-9]+)$ ]]; then
        set_index "${BASH_REMATCH[1]}" 1
    elif [[ "$token" =~ ^-([0-9]+)$ ]]; then
        set_index "${BASH_REMATCH[1]}" 0
    elif [[ "$token" =~ ^([0-9]+)-([0-9]+)$ ]]; then
        start=$((10#${BASH_REMATCH[1]}))
        end=$((10#${BASH_REMATCH[2]}))
        if [ "$start" -gt "$end" ]; then
            n=$start
            start=$end
            end=$n
        fi
        for ((n = start; n <= end; n++)); do
            toggle_index "$n" || return 1
        done
    else
        echo "Unknown choice: $token" >&2
        return 1
    fi
}

apply_tokens() {
    local raw="$1" token
    local -a tokens=() pending_entry=() pending_on=()

    # Validate the whole line before changing anything, so a typo does not
    # toggle the numbers that came before it.
    pending_entry=("${items_entry[@]}")
    pending_on=("${items_on[@]}")
    read -ra tokens <<< "${raw//,/ }"
    if [ "${#tokens[@]}" -eq 0 ]; then
        echo "Enter a number, 'select ALL', 'select NONE', or press enter to save." >&2
        return 1
    fi
    for token in "${tokens[@]}"; do
        apply_token "$token" || {
            items_entry=("${pending_entry[@]}")
            items_on=("${pending_on[@]}")
            return 1
        }
    done
}

save_selection() {
    local dir base tmp i entry on shown=0
    dir=$(dirname -- "$SELECTION_FILE")
    base=$(basename -- "$SELECTION_FILE")
    if [ ! -d "$dir" ] || [ ! -w "$dir" ]; then
        echo "❌ Cannot write selection file: $SELECTION_FILE" >&2
        return 1
    fi
    tmp=$(mktemp "$dir/.$base.XXXXXX") || {
        echo "❌ Cannot write selection file: $SELECTION_FILE" >&2
        return 1
    }
    {
        echo "# aidev-selection-v1"
        echo "# Written by aidev_select.sh. Enabled lines run. Disabled tools are commented and stay in the menu."
        for i in "${!items_entry[@]}"; do
            entry="${items_entry[$i]}"
            on="${items_on[$i]}"
            if [ "$on" -eq 1 ]; then
                shown=$((shown + 1))
                printf '%s\n' "$entry"
            else
                printf '%s\n' "# disabled: $entry"
            fi
        done
    } > "$tmp" || {
        rm -f "$tmp"
        echo "❌ Cannot write selection file: $SELECTION_FILE" >&2
        return 1
    }
    if ! mv -f "$tmp" "$SELECTION_FILE"; then
        rm -f "$tmp"
        echo "❌ Cannot write selection file: $SELECTION_FILE" >&2
        return 1
    fi
    if [ -t 1 ]; then
        printf '\033[H\033[2J'
    fi
    echo "Saved $shown of ${#items_entry[@]} tools to $SELECTION_FILE"
}

menu_loop() {
    local reply low
    while true; do
        draw_menu
        if [ -t 0 ]; then
            read -r -p "Choice: " reply || reply="q"
        else
            IFS= read -r reply || reply="q"
        fi
        reply=$(trim_line "$reply")
        low="${reply,,}"
        case "$low" in
            ""|g|go|ok|s|save|c|continue)
                save_selection
                return $?
                ;;
            q|quit|exit)
                echo "Update cancelled. Saved selection was not changed."
                return 2
                ;;
            a|all|"select all")
                set_all 1
                ;;
            n|none|"select none")
                set_all 0
                ;;
            *)
                apply_tokens "$reply" || true
                ;;
        esac
    done
}

while [ $# -gt 0 ]; do
    case "$1" in
        --catalog)
            [ $# -ge 2 ] || { echo "Missing value for --catalog" >&2; exit 2; }
            CATALOG_FILE="$2"
            shift 2
            ;;
        --selection)
            [ $# -ge 2 ] || { echo "Missing value for --selection" >&2; exit 2; }
            SELECTION_FILE="$2"
            shift 2
            ;;
        --force)
            FORCE=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

if [ -z "$CATALOG_FILE" ] || [ -z "$SELECTION_FILE" ]; then
    usage >&2
    exit 2
fi
if [ ! -f "$CATALOG_FILE" ]; then
    echo "❌ Catalog not found: $CATALOG_FILE" >&2
    exit 2
fi

# aidev_update.sh only calls this on a terminal. A piped or redirected run
# keeps the saved file and does not block waiting for a prompt.
if [ "$FORCE" -eq 0 ] && { [ ! -t 0 ] || [ ! -t 1 ]; }; then
    exit 0
fi

load_catalog
load_selection
if [ "${#cat_entries[@]}" -eq 0 ] && [ "${#file_entries[@]}" -eq 0 ]; then
    echo "❌ No tools to choose from." >&2
    exit 2
fi
build_items
menu_loop
exit $?
