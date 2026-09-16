#!/bin/bash
#
# aidev_update.sh - update orchestrator for AI dev CLI tools.
#
# Runs a configurable list of updater steps, either sequentially (default) or
# up to N at a time with --jobs. Every step is executed even if an earlier one
# fails; a summary is printed at the end and the script exits non-zero if any
# step failed.
#
# Run './aidev_update.sh --help' for usage, options, environment variables and
# examples. Full documentation lives in README.md.

# Note: we deliberately do not use 'set -e' so a single failing update does not
# abort the rest of the run. Failures are collected and reported instead.
set -u
set -o pipefail

# Directory where this script lives.
# Resolve symlinks so SCRIPT_DIR points to the actual repository directory even
# when invoked via a symlink in PATH (e.g. ~/.local/bin/aidev_update).
SOURCE="${BASH_SOURCE[0]}"
if command -v readlink >/dev/null 2>&1; then
    while [ -L "$SOURCE" ]; do
        DIR="$(cd -P "$(dirname "$SOURCE")" >/dev/null 2>&1 && pwd)"
        SOURCE="$(readlink "$SOURCE")"
        [[ "$SOURCE" != /* ]] && SOURCE="$DIR/$SOURCE"
    done
fi
SCRIPT_DIR="$(cd -P "$(dirname "$SOURCE")" >/dev/null 2>&1 && pwd)"

VERSION="1.4.0"

# Captured before option parsing consumes "$@", so the run log can record how
# the run was actually invoked.
RUN_ARGV=("$@")

# The script relies on bash 4.4+ features (case-folding, empty-array expansion
# under 'set -u'). Fail fast with a clear message instead of a syntax error.
if [ -z "${BASH_VERSINFO:-}" ] || \
   [ "${BASH_VERSINFO[0]}" -lt 4 ] || \
   { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -lt 4 ]; }; then
    echo "❌ aidev_update.sh requires bash >= 4.4 (found: ${BASH_VERSION:-unknown})." >&2
    exit 1
fi

# Fractional 'sleep 0.1' is used for fast polling; detect support once so we
# can fall back to whole-second polling on systems whose sleep(1) rejects it.
FRACTIONAL_SLEEP=1
if ! sleep 0.1 >/dev/null 2>&1; then
    FRACTIONAL_SLEEP=0
fi

# Defaults are applied here; the values themselves are sanitized by
# validate_env once, right after option parsing. Warnings are queued rather
# than printed so they land in the run log as well as on the terminal.
AIDEV_TIMEOUT="${AIDEV_TIMEOUT:-600}"

# Seconds to wait after SIGTERM before killing a hung step. timeout(1) exits
# 124 when it has to kill the step (TERM or KILL escalation); see classify_rc
# for how that is distinguished from a step's own exit code.
AIDEV_KILL_AFTER="${AIDEV_KILL_AFTER:-10}"

AIDEV_LOG_RETENTION_DAYS="${AIDEV_LOG_RETENTION_DAYS:-30}"

# Attempts per step when it exits non-zero (timeouts are not retried).
AIDEV_RETRIES="${AIDEV_RETRIES:-1}"

# Sanitize the tunables above, falling back to defaults for bad values.
# Warnings are queued in EARLY_WARNINGS and printed once logging is engaged
# (or immediately, when logging is disabled), so they land in the log file.
EARLY_WARNINGS=()
validate_env() {
    if ! [[ "$AIDEV_TIMEOUT" =~ ^[0-9]+$ ]]; then
        EARLY_WARNINGS+=("⚠ AIDEV_TIMEOUT must be a whole number of seconds; using 600.")
        AIDEV_TIMEOUT=600
    fi
    if ! [[ "$AIDEV_KILL_AFTER" =~ ^[0-9]+$ ]]; then
        EARLY_WARNINGS+=("⚠ AIDEV_KILL_AFTER must be a whole number of seconds; using 10.")
        AIDEV_KILL_AFTER=10
    fi
    if ! [[ "$AIDEV_LOG_RETENTION_DAYS" =~ ^[0-9]+$ ]]; then
        EARLY_WARNINGS+=("⚠ AIDEV_LOG_RETENTION_DAYS must be a whole number of days; using 30.")
        AIDEV_LOG_RETENTION_DAYS=30
    fi
    if ! [[ "$AIDEV_RETRIES" =~ ^[0-9]+$ ]] || [ "$AIDEV_RETRIES" -lt 1 ]; then
        EARLY_WARNINGS+=("⚠ AIDEV_RETRIES must be a whole number >= 1; using 1.")
        AIDEV_RETRIES=1
    fi
}

# ---------------------------------------------------------------------------
# Step configuration
#
# Format: "kind|target|description"
#   kind=script  target is a sibling updater script (run with bash)
#   kind=cmd     target is a shell command (word-split into argv)
#   kind=sh      target is a shell snippet (evaluated with bash -c)
#
# Any other kind is reported as a configuration error rather than guessed at.
#
# Note: 'cmd' targets are split on whitespace only. Quoting, escapes and paths
# containing spaces are NOT supported; use a small wrapper script for those.
#
# To enable/disable a step, move its line between STEPS and DISABLED_STEPS.
# ---------------------------------------------------------------------------
STEPS=(
    "script|openspec_update.sh|OpenSpec Update"
    "script|mini_swe_agent_update.sh|mini-swe-agent Update"
    "cmd|claude update|Claude Code CLI Update"
    "script|grok_update.sh|Grok CLI Update"
    "cmd|droid update|DROID CLI Update"
    "script|codex_update.sh|OpenAI Codex Update"
    "script|opencode_update.sh|OpenCode CLI Update"
    "script|entire_update.sh|Entire Update"
    "script|headroom_update.sh|Headroom Update"
    "script|kilo_update.sh|Kilo Update"
    "script|beads_update.sh|Beads Update"
    "script|gastown_update.sh|Gastown Update"
    "script|gastown_gui_update.sh|Gastown GUI Update"
    "script|repowise_update.sh|Repowise Update"
)

# Kept for reference; not executed. Move a line into STEPS to re-enable it.
DISABLED_STEPS=(
    "script|claude_update.sh|Claude Code CLI Update (replaced by 'claude update')"
    "cmd|copilot update|Copilot Update"
    "script|ccr_update.sh|Claude Code Router Update"
    "script|gemini_update.sh|Gemini CLI Update"
    "script|qwen_update.sh|Qwen Code Update"
    "script|amp_update.sh|Amp Code Update"
    "script|llxprt_update.sh|LLxprt Code Update"
    "script|justcode_update.sh|JustCode Update"
    "script|codebuff_update.sh|Codebuff Update"
    "script|tm_update.sh|Taskmaster Update"
    "cmd|task-master --version|Taskmaster Version"
    "script|cliproxyapi_update.sh|CLIProxyAPI Update"
    "script|ollama_update.sh|Ollama Update"
    "script|pi_update.sh|Pi Coding Agent Update"
)

# ---------------------------------------------------------------------------
# Optional external step table
#
# Keeping the list in a file makes enabling or disabling a tool a local config
# change instead of a diff against the orchestrator itself. The arrays above
# are the fallback when no config file is present, so the default install
# stays zero-config.
# ---------------------------------------------------------------------------
STEPS_SOURCE="built-in step table"

# Replace STEPS from the given file. Returns 1 (leaving STEPS untouched) when
# the file yields no usable entries.
load_steps_file() {
    local file="$1" line kind target description
    local lineno=0
    local -a loaded=()

    while IFS= read -r line || [ -n "$line" ]; do
        lineno=$((lineno + 1))
        line="${line%$'\r'}"                       # tolerate CRLF
        line="${line#"${line%%[![:space:]]*}"}"     # strip leading blanks
        [ -z "$line" ] && continue
        [ "${line:0:1}" = "#" ] && continue

        IFS='|' read -r kind target description <<< "$line"
        if [ -z "$kind" ] || [ -z "$target" ] || [ -z "${description:-}" ]; then
            EARLY_WARNINGS+=("⚠ Ignoring malformed step at $file:$lineno (expected kind|target|description).")
            continue
        fi
        loaded+=("$kind|$target|$description")
    done < "$file"

    if [ "${#loaded[@]}" -eq 0 ]; then
        EARLY_WARNINGS+=("⚠ No usable steps in $file; using the built-in step table.")
        return 1
    fi

    STEPS=("${loaded[@]}")
    # The file is the whole truth about which steps exist; carrying the
    # built-in "disabled" list alongside it would just be confusing.
    DISABLED_STEPS=()
    STEPS_SOURCE="$file"
    return 0
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

usage() {
    cat <<EOF
aidev_update.sh v${VERSION} - update orchestrator for AI dev CLI tools

Usage: aidev_update.sh [options] [name ...]

Options:
  --only PATTERN          Run only steps whose target/description matches PATTERN.
                          Repeatable. A bare positional name is treated as --only.
  --skip PATTERN          Skip steps whose target/description matches PATTERN.
  --jobs N                Run up to N steps at the same time (default: 1). Each
                          step's output is buffered and printed when the step
                          finishes, so parallel runs stay readable.
  -t, --timeout SECONDS   Per-step timeout in seconds (default: 600; 0 disables).
  -k, --kill-after SECS   Grace period after SIGTERM before SIGKILL (default: 10).
  -r, --retries N         Attempts per failed step (default: 1, i.e. no retry).
  --require LIST          Comma/space separated tools that must exist before
                          anything runs; missing ones abort with exit 4.
  --no-log                Disable writing to a run log file.
  --log-dir DIR           Directory for run logs (default: <script dir>/logs).
  --dry-run               Show which steps would run (and which would be skipped),
                          then exit without updating anything.
  --list                  List configured steps and their current availability.
  -v, --version           Show version information.
  -h, --help              Show this help.
  --                      Stop option processing; remaining arguments are treated
                          as positional patterns.

Notes:
  - PATTERN matching is a case-insensitive substring test against both the
    step target and its description, so a broad pattern like 'update' or
    'open' can match several steps at once.
  - 'cmd' steps are split on whitespace only. 'sh' steps are evaluated with
    bash -c (supporting quotes, pipes and flags).
  - npm and curl are only advisory: a missing tool is reported, but it aborts
    the run only when named by --require / AIDEV_REQUIRE.
  - A 'steps.conf' next to the script (or AIDEV_STEPS_FILE) replaces the
    built-in step table. Format is one 'kind|target|description' per line;
    blank lines and '#' comments are ignored.

Exit codes:
  0  every attempted step succeeded (skipped steps are allowed)
  1  one or more steps failed or timed out
  2  invalid usage, or no step matched the --only/--skip filters
  3  another run is already in progress
  4  a tool named by --require / AIDEV_REQUIRE is missing

Environment:
  AIDEV_TIMEOUT              Per-step timeout in seconds (default: 600).
                             0 disables the timeout entirely.
  AIDEV_KILL_AFTER           Grace period after SIGTERM before SIGKILL
                             (default: 10).
  AIDEV_RETRIES              Attempts per failed step (default: 1, i.e. no
                             retry). Only non-zero exits are retried.
  AIDEV_REQUIRE              Comma/space separated tools that must exist
                             before anything runs (default: none).
  AIDEV_STEPS_FILE           Step table to use instead of the built-in one
                             (default: <script dir>/steps.conf when present).
  AIDEV_LOG_DIR              Directory for run logs (default: <script dir>/logs).
  AIDEV_LOG_RETENTION_DAYS   Delete run logs older than this many days
                             (default: 30; 0 disables pruning).
  AIDEV_NO_LOG               Set to 1 to disable logging.

Examples:
  aidev_update.sh                     # run everything
  aidev_update.sh --only grok         # just the Grok updater
  aidev_update.sh --skip gastown      # everything except Gastown
  aidev_update.sh --jobs 4            # run up to 4 steps in parallel
  aidev_update.sh --dry-run           # show what would happen
  aidev_update.sh --timeout 120       # 2 minute cap per step
  aidev_update.sh --retries 2         # one extra try on failure
EOF
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

print_header() {
    echo ""
    echo "====================================="
    echo "$1"
    echo "====================================="
}

# Case-insensitive substring match of $1 against the remaining patterns.
matches_patterns() {
    local haystack="${1,,}"
    shift
    local pattern
    for pattern in "$@"; do
        [ -n "$pattern" ] || continue
        if [[ "$haystack" == *"${pattern,,}"* ]]; then
            return 0
        fi
    done
    return 1
}

# Poll until PID exits or the timeout (seconds) elapses. Returns 1 on timeout.
# Note: bash reaps its own background children as they exit, so 'kill -0'
# starts failing as soon as the child is gone, before any explicit 'wait'.
# This is used only to bound waits, never to collect a step's exit status.
wait_for_pid() {
    local pid="$1" limit="${2:-5}"
    local ticks="$limit"
    [ "$FRACTIONAL_SLEEP" = 1 ] && ticks=$((limit * 10))
    local i=0
    while kill -0 "$pid" 2>/dev/null; do
        [ "$i" -ge "$ticks" ] && return 1
        if [ "$FRACTIONAL_SLEEP" = 1 ]; then sleep 0.1; else sleep 1; fi
        i=$((i + 1))
    done
    return 0
}

# Globals set by resolve_step.
STEP_CMD=()
STEP_SKIP_REASON=""

# Globals set by classify_rc / execute_step.
# STEP_SECONDS covers every attempt of a step; STEP_ATTEMPT_SECONDS covers only
# the last one, which is what the timeout summary line reports.
STEP_STATUS=""
STEP_SECONDS=0
STEP_ATTEMPT_SECONDS=0
STEP_RC=0

# Resolve a step into a runnable argv in STEP_CMD. Returns 0 if it can run, or
# 1 (with STEP_SKIP_REASON set) if it should be skipped. Shared by the preflight
# pass, --dry-run and execute_step so the availability rules live in one place.
# Classify a finished step into STEP_STATUS (ok|fail|timeout) from its exit
# code, elapsed seconds, and whether it was wrapped in timeout(1).
#
# A step that exits 124/137 on its own must NOT be reported as a timeout:
#  - without the timeout(1) wrapper the code can only come from the step;
#  - with the wrapper, a real timeout always runs at least AIDEV_TIMEOUT
#    seconds (an integer-length interval always crosses that many second
#    boundaries), so a faster 124/137 is the step's own exit code.
classify_rc() {
    local rc="$1" seconds="$2" used_timeout="$3"
    if [ "$rc" -eq 0 ]; then
        STEP_STATUS="ok"
    elif { [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; } \
          && [ "$used_timeout" = 1 ] \
          && [ "$AIDEV_TIMEOUT" -gt 0 ] \
          && [ "$seconds" -ge "$AIDEV_TIMEOUT" ]; then
        STEP_STATUS="timeout"
    else
        STEP_STATUS="fail"
    fi
}

resolve_step() {
    local kind="$1" target="$2"
    STEP_CMD=()
    STEP_SKIP_REASON=""

    if [ "$kind" = "cmd" ]; then
        read -ra STEP_CMD <<< "$target"
        if [ "${#STEP_CMD[@]}" -eq 0 ]; then
            STEP_SKIP_REASON="empty command"
            return 1
        fi
        if ! command_exists "${STEP_CMD[0]}"; then
            STEP_SKIP_REASON="command not found: ${STEP_CMD[0]}"
            return 1
        fi
    elif [ "$kind" = "sh" ]; then
        if [[ "$target" =~ ^[[:space:]]*$ ]]; then
            STEP_SKIP_REASON="empty shell command"
            return 1
        fi
        STEP_CMD=(bash -c "$target")
    elif [ "$kind" = "script" ]; then
        local script_path="$target"
        [[ "$script_path" != /* ]] && script_path="$SCRIPT_DIR/$target"
        if [ ! -f "$script_path" ]; then
            STEP_SKIP_REASON="script not found: $target"
            return 1
        fi
        if [ ! -r "$script_path" ]; then
            STEP_SKIP_REASON="script not readable: $target"
            return 1
        fi
        STEP_CMD=(bash "$script_path")
    else
        # A typo in the step table must name itself, not masquerade as a
        # missing script.
        STEP_SKIP_REASON="unknown step kind: $kind"
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
ONLY_PATTERNS=()
SKIP_PATTERNS=()
JOBS=1
LIST_ONLY=0
DRY_RUN=0

# Option-parsing helpers. Every value-taking option needs the same three
# checks; keeping them in one place is what stops the '--opt value' and
# '--opt=value' spellings from drifting apart.
die_usage() {
    echo "$1" >&2
    echo "Run '$(basename "$0") --help' for usage." >&2
    exit 2
}

require_value() {
    [ "$2" -gt 0 ] || die_usage "Missing value for $1"
}

require_nonempty() {
    [ -n "$2" ] || die_usage "Option $1 requires a non-empty argument"
}

require_uint() {
    local opt="$1" val="$2" min="${3:-0}"
    [[ "$val" =~ ^[0-9]+$ ]] && [ "$val" -ge "$min" ] || \
        die_usage "$opt must be a whole number >= $min"
}

while [ $# -gt 0 ]; do
    opt="$1"
    val=""
    has_val=0

    # Split '--opt=value' (and '-t=value') once, so the two spellings of an
    # option share a single implementation below.
    case "$opt" in
        --*=*|-[tkr]=*)
            val="${opt#*=}"
            opt="${opt%%=*}"
            has_val=1
            ;;
    esac

    # Options that take a value pull it from the next argument unless it
    # already arrived in '=value' form.
    case "$opt" in
        --only|--skip|--jobs|-t|--timeout|-k|--kill-after|-r|--retries|--log-dir|--require)
            if [ "$has_val" -eq 0 ]; then
                require_value "$opt" $(($# - 1))
                val="$2"
                shift
            fi
            ;;
    esac

    case "$opt" in
        --only)          require_nonempty "$opt" "$val"; ONLY_PATTERNS+=("$val") ;;
        --skip)          require_nonempty "$opt" "$val"; SKIP_PATTERNS+=("$val") ;;
        --jobs)          require_uint "$opt" "$val" 1; JOBS="$val" ;;
        -t|--timeout)    require_uint "$opt" "$val" 0; AIDEV_TIMEOUT="$val" ;;
        -k|--kill-after) require_uint "$opt" "$val" 0; AIDEV_KILL_AFTER="$val" ;;
        -r|--retries)    require_uint "$opt" "$val" 1; AIDEV_RETRIES="$val" ;;
        --log-dir)       require_nonempty "$opt" "$val"; AIDEV_LOG_DIR="$val" ;;
        --require)       require_nonempty "$opt" "$val"; AIDEV_REQUIRE="$val" ;;
        --no-log)        AIDEV_NO_LOG=1 ;;
        --dry-run)       DRY_RUN=1 ;;
        --list)          LIST_ONLY=1 ;;
        -v|--version)    echo "aidev_update.sh v${VERSION}"; exit 0 ;;
        -h|--help)       usage; exit 0 ;;
        --)
            shift
            while [ $# -gt 0 ]; do
                ONLY_PATTERNS+=("$1")
                shift
            done
            break
            ;;
        -*)
            die_usage "Unknown option: $1"
            ;;
        *) ONLY_PATTERNS+=("$opt") ;;
    esac
    shift
done

# Sanitize the tunables once, before anything consumes them (prune_logs reads
# AIDEV_LOG_RETENTION_DAYS later); warnings are replayed once logging is up.
validate_env

if [ -n "${AIDEV_STEPS_FILE:-}" ]; then
    if [ ! -f "$AIDEV_STEPS_FILE" ]; then
        echo "❌ AIDEV_STEPS_FILE not found: $AIDEV_STEPS_FILE" >&2
        exit 2
    fi
    load_steps_file "$AIDEV_STEPS_FILE" || true
elif [ -f "$SCRIPT_DIR/steps.conf" ]; then
    load_steps_file "$SCRIPT_DIR/steps.conf" || true
fi

if [ "$LIST_ONLY" -eq 1 ]; then
    if [ ${#EARLY_WARNINGS[@]} -gt 0 ]; then
        printf '%s\n' "${EARLY_WARNINGS[@]}" >&2
    fi
    echo "Steps from: $STEPS_SOURCE"
    echo ""
    echo "Enabled steps:"
    for entry in "${STEPS[@]}"; do
        IFS='|' read -r kind target description <<< "$entry"
        if resolve_step "$kind" "$target"; then
            state="runnable"
        else
            state="skip: $STEP_SKIP_REASON"
        fi
        printf '  %-28s %-46s [%s]\n' "$target" "$description" "$state"
    done
    if [ ${#DISABLED_STEPS[@]} -gt 0 ]; then
        echo ""
        echo "Disabled steps (kept for reference; move a line into STEPS to enable):"
        for entry in "${DISABLED_STEPS[@]}"; do
            IFS='|' read -r _ target description <<< "$entry"
            printf '  %-28s %s\n' "$target" "$description"
        done
    fi
    exit 0
fi

# ---------------------------------------------------------------------------
# Select steps (apply --only / --skip before touching anything)
# ---------------------------------------------------------------------------
selected_entries=()

for entry in "${STEPS[@]}"; do
    IFS='|' read -r kind target description <<< "$entry"

    if [ ${#ONLY_PATTERNS[@]} -gt 0 ] && \
       ! matches_patterns "$target $description" "${ONLY_PATTERNS[@]}"; then
        continue
    fi
    if [ ${#SKIP_PATTERNS[@]} -gt 0 ] && \
       matches_patterns "$target $description" "${SKIP_PATTERNS[@]}"; then
        continue
    fi

    selected_entries+=("$entry")
done

if [ ${#selected_entries[@]} -eq 0 ]; then
    echo "⚠ No steps matched the given --only/--skip filters." >&2
    echo "Available steps:" >&2
    for entry in "${STEPS[@]}"; do
        IFS='|' read -r _ target description <<< "$entry"
        printf '  %-28s %s\n' "$target" "$description" >&2
    done
    echo "Run '$(basename "$0") --list' for availability details." >&2
    exit 2
fi

# ---------------------------------------------------------------------------
# Dry run: resolve every selected step and report without changing anything.
# ---------------------------------------------------------------------------
if [ "$DRY_RUN" -eq 1 ]; then
    if [ ${#EARLY_WARNINGS[@]} -gt 0 ]; then
        printf '%s\n' "${EARLY_WARNINGS[@]}" >&2
    fi
    echo "Dry run: ${#selected_entries[@]} step(s) selected"
    for entry in "${selected_entries[@]}"; do
        IFS='|' read -r kind target description <<< "$entry"
        if resolve_step "$kind" "$target"; then
            printf '  [would run] %-40s (%s: %s)\n' "$description" "$kind" "$target"
            printf '              argv: %s\n' "${STEP_CMD[*]}"
        else
            printf '  [skip]      %-40s (%s)\n' "$description" "$STEP_SKIP_REASON"
        fi
    done
    exit 0
fi

# ---------------------------------------------------------------------------
# Concurrency guard: a second run would race the package managers. The lock is
# best-effort: if the lock file cannot even be opened (e.g. a read-only
# install directory), warn and continue instead of dying with a cryptic
# redirection error.
# ---------------------------------------------------------------------------
LOCK_FILE=""
if command_exists flock; then
    LOCK_FILE="$SCRIPT_DIR/.aidev_update.lock"
    # Steps are launched with '8>&-' so they (and any daemons they leave
    # behind) never inherit the lock fd; without that, a surviving daemon
    # would hold the flock and wedge every future run.
    if : >> "$LOCK_FILE" 2>/dev/null && exec 8>>"$LOCK_FILE"; then
        if flock -n 8; then
            printf '%s\n' "$$" > "$LOCK_FILE" 2>/dev/null || true
        else
            holder=""
            if [ -r "$LOCK_FILE" ]; then
                read -r holder < "$LOCK_FILE" 2>/dev/null || true
            fi
            if [ -n "$holder" ]; then
                echo "❌ Another aidev_update.sh run is in progress (held by PID $holder, lock: $LOCK_FILE)." >&2
            else
                echo "❌ Another aidev_update.sh run is in progress (lock: $LOCK_FILE)." >&2
            fi
            exit 3
        fi
    else
        echo "⚠ Cannot open lock file ($LOCK_FILE); continuing without a concurrency guard." >&2
        LOCK_FILE=""
    fi
fi

# ---------------------------------------------------------------------------
# Signal handling: forward termination to the running step(s), then exit via
# the normal EXIT trap so logging is still cleaned up. Exit codes follow the
# usual convention: 128 + signal number (130 for SIGINT, 143 for SIGTERM).
#
# STEP_CHILDREN holds the pids of running steps (one in sequential mode,
# up to --jobs N in parallel mode).
# ---------------------------------------------------------------------------
STEP_CHILDREN=()
# Predeclare the globals the handler and the EXIT trap reference even if a
# signal arrives before logging/parallel mode is set up.
TEE_PID=""
LOG_FIFO=""
PAR_TMPDIR=""

# Signal a step's whole descendant tree, deepest first, then the step itself.
# Signalling only the direct child would orphan grandchildren: parallel steps
# run inside a wrapper subshell (see run_steps_parallel), and steps like npm
# spawn children of their own.
kill_tree() {
    local pid="$1" sig="${2:-TERM}" child
    if command_exists pgrep; then
        for child in $(pgrep -P "$pid" 2>/dev/null); do
            kill_tree "$child" "$sig"
        done
    fi
    kill "-$sig" "$pid" 2>/dev/null
    return 0
}

on_signal() {
    local code="$1"
    local pid

    # Broadcast SIGTERM to all active step trees immediately so concurrent
    # workers stop simultaneously instead of waiting sequentially.
    if [ "${#STEP_CHILDREN[@]}" -gt 0 ]; then
        for pid in "${STEP_CHILDREN[@]}"; do
            kill_tree "$pid" TERM
        done
    fi

    # Sweep any other direct children to close the launch race window: a step
    # started microseconds ago may not be recorded in STEP_CHILDREN yet. The
    # log tee (TEE_PID) is deliberately excluded so the EXIT trap can flush.
    if command_exists pgrep; then
        for pid in $(pgrep -P "$$" 2>/dev/null); do
            [ "$pid" = "$TEE_PID" ] && continue
            kill_tree "$pid" TERM
        done
    fi

    # Wait for step children; escalate to SIGKILL for any that do not exit.
    if [ "${#STEP_CHILDREN[@]}" -gt 0 ]; then
        for pid in "${STEP_CHILDREN[@]}"; do
            if ! wait_for_pid "$pid" "$AIDEV_KILL_AFTER"; then
                kill_tree "$pid" 9
                wait_for_pid "$pid" 2
            fi
            wait "$pid" 2>/dev/null
        done
    fi

    exit "$code"
}
trap 'on_signal 130' INT
trap 'on_signal 143' TERM
# Without this, closing a terminal or SSH session kills the run outright: steps
# keep running, the log FIFO is never flushed and temp dirs are left behind.
trap 'on_signal 129' HUP

# ---------------------------------------------------------------------------
# Logging: tee all output to a log file. A FIFO is used (rather than process
# substitution) so the script waits for tee to flush before exiting, keeping
# ordering intact even when output is itself piped somewhere.
#
# The FIFO write-end open blocks until a reader exists, so we only engage
# logging when both mkfifo and tee are available; otherwise a missing tee would
# hang the script forever.
# ---------------------------------------------------------------------------
LOG_FILE=""
LOG_FIFO=""
TEE_PID=""
ORIG_STDOUT_SAVED=0

cleanup_logging() {
    if [ -n "$LOG_FIFO" ]; then
        # Restore original terminal stdout/stderr so later operations or traps
        # do not fail with Bad file descriptor, and close the FIFO write end
        # so tee sees EOF.
        if [ "$ORIG_STDOUT_SAVED" -eq 1 ]; then
            exec 1>&3 2>&4 3>&- 4>&-
            ORIG_STDOUT_SAVED=0
        else
            exec 1>&- 2>&-
        fi
        if [ -n "$TEE_PID" ]; then
            # An orphaned grandchild may still hold the pipe open; never block
            # the run forever waiting for tee.
            if ! wait_for_pid "$TEE_PID" 5; then
                kill "$TEE_PID" 2>/dev/null
                if ! wait_for_pid "$TEE_PID" 2; then
                    kill -9 "$TEE_PID" 2>/dev/null
                fi
            fi
            wait "$TEE_PID" 2>/dev/null
            TEE_PID=""
        fi
        [ -p "$LOG_FIFO" ] && rm -f "$LOG_FIFO"
        LOG_FIFO=""
    fi
}
# EXIT trap: remove the parallel-mode temp dir (also on signal-interrupted
# runs) and then flush/close the logging pipeline.
on_exit() {
    if [ -n "$PAR_TMPDIR" ]; then
        rm -rf "$PAR_TMPDIR"
        PAR_TMPDIR=""
    fi
    cleanup_logging
}
trap on_exit EXIT

prune_logs() {
    local dir="$1" days="$2"
    if ! command_exists find; then
        echo "⚠ 'find' not found; log pruning disabled." >&2
        return 0
    fi
    # Prune stale named pipes left behind by crashed/killed runs.
    find "$dir" -maxdepth 1 -type p -name '.aidev-*.fifo' -mtime +1 -delete 2>/dev/null || true
    [ "$days" -gt 0 ] || return 0
    find "$dir" -maxdepth 1 -type f -name 'aidev-*.log' \
        -mtime +"$days" -delete 2>/dev/null || true
}

if [ "${AIDEV_NO_LOG:-0}" != "1" ]; then
    if ! command_exists mkfifo || ! command_exists tee; then
        echo "⚠ mkfifo/tee not available; logging disabled." >&2
    else
        LOG_DIR="${AIDEV_LOG_DIR:-$SCRIPT_DIR/logs}"
        if mkdir -p "$LOG_DIR" && [ -w "$LOG_DIR" ]; then
            prune_logs "$LOG_DIR" "$AIDEV_LOG_RETENTION_DAYS"
            LOG_FILE="$LOG_DIR/aidev-$(date +%Y%m%d-%H%M%S)-$$.log"
            LOG_FIFO="$LOG_DIR/.aidev-$$.fifo"
            rm -f "$LOG_FIFO"
            if mkfifo "$LOG_FIFO"; then
                tee -a "$LOG_FILE" < "$LOG_FIFO" &
                TEE_PID=$!
                exec 3>&1 4>&2 > "$LOG_FIFO" 2>&1
                ORIG_STDOUT_SAVED=1
            else
                echo "⚠ Could not create log FIFO; logging disabled." >&2
                LOG_FILE=""
                LOG_FIFO=""
            fi
        else
            echo "⚠ Log directory not writable: $LOG_DIR; logging disabled." >&2
            LOG_FILE=""
        fi
    fi
fi

if [ ${#EARLY_WARNINGS[@]} -gt 0 ]; then
    printf '%s\n' "${EARLY_WARNINGS[@]}" >&2
fi

RUN_STARTED=$(date '+%Y-%m-%d %H:%M:%S')
RUN_HOST="$(hostname 2>/dev/null || uname -n 2>/dev/null || echo unknown)"
# Recorded so a log read weeks later still says which orchestrator produced it,
# where, and with which arguments.
echo "AIDev update run started: $RUN_STARTED"
printf 'Version:  %s\n' "$VERSION"
printf 'Host:     %s\n' "$RUN_HOST"
printf 'Command:  %s\n' "$(basename "$0") ${RUN_ARGV[*]+${RUN_ARGV[*]}}"
printf 'Steps:    %s\n' "$STEPS_SOURCE"
if [ -n "$LOG_FILE" ]; then
    printf 'Log file: %s\n' "$LOG_FILE"
fi

# ---------------------------------------------------------------------------
# Dependency check
#
# The orchestrator itself needs nothing beyond coreutils: npm, curl and friends
# are needs of individual updater scripts, and which ones matter depends on
# which steps were selected. So the common tools are only advisory here (a step
# that truly needs one fails on its own, with its own message), while
# --require / AIDEV_REQUIRE lets a caller demand tools up front and abort with
# exit 4 when they are absent.
# ---------------------------------------------------------------------------
echo ""
echo "Checking dependencies..."

required_deps=()
if [ -n "${AIDEV_REQUIRE:-}" ]; then
    # Accept commas or whitespace as separators.
    IFS=', ' read -ra required_deps <<< "$AIDEV_REQUIRE"
fi

missing_required=()
for dep in ${required_deps[@]+"${required_deps[@]}"}; do
    [ -n "$dep" ] || continue
    command_exists "$dep" || missing_required+=("$dep")
done

if [ ${#missing_required[@]} -ne 0 ]; then
    echo "❌ Missing required dependencies: ${missing_required[*]}"
    echo "Please install the missing dependencies and try again."
    exit 4
fi

missing_deps=()
for dep in npm curl; do
    command_exists "$dep" || missing_deps+=("$dep")
done

if [ ${#missing_deps[@]} -ne 0 ]; then
    echo "⚠ Not found: ${missing_deps[*]} — steps that need them will fail."
else
    echo "✓ All common dependencies found"
fi

# ---------------------------------------------------------------------------
# Preflight: report steps that cannot run before we start updating anything.
# ---------------------------------------------------------------------------
preflight_problems=()
for entry in "${selected_entries[@]}"; do
    IFS='|' read -r kind target description <<< "$entry"
    if ! resolve_step "$kind" "$target"; then
        preflight_problems+=("$description ($STEP_SKIP_REASON)")
    fi
done

if [ ${#preflight_problems[@]} -gt 0 ]; then
    echo ""
    echo "⚠ The following steps will be skipped:"
    for problem in "${preflight_problems[@]}"; do
        printf '  - %s\n' "$problem"
    done
fi

# ---------------------------------------------------------------------------
# Run one step (sequential mode). Sets STEP_STATUS to ok|fail|timeout|skip,
# STEP_SECONDS (total across attempts) and STEP_RC. A step that exits
# non-zero is retried up to AIDEV_RETRIES total attempts; timeouts are not.
# ---------------------------------------------------------------------------
execute_step() {
    local kind="$1" target="$2" description="$3"

    STEP_STATUS=""
    STEP_SECONDS=0
    STEP_ATTEMPT_SECONDS=0
    STEP_RC=0

    if ! resolve_step "$kind" "$target"; then
        echo "⚠ ${STEP_SKIP_REASON}"
        STEP_STATUS="skip"
        STEP_RC=""
        return
    fi

    local total_started=$SECONDS
    local attempt=1

    while :; do
        local started=$SECONDS
        local rc=0 used_timeout=0

        if command_exists timeout && [ "$AIDEV_TIMEOUT" -gt 0 ]; then
            used_timeout=1
            timeout --kill-after="$AIDEV_KILL_AFTER" "$AIDEV_TIMEOUT" \
                "${STEP_CMD[@]}" < /dev/null 3>&- 4>&- 8>&- &
        else
            "${STEP_CMD[@]}" < /dev/null 3>&- 4>&- 8>&- &
        fi
        STEP_CHILDREN=($!)
        wait "${STEP_CHILDREN[0]}" || rc=$?
        STEP_CHILDREN=()

        local attempt_seconds=$((SECONDS - started))
        classify_rc "$rc" "$attempt_seconds" "$used_timeout"
        STEP_ATTEMPT_SECONDS=$attempt_seconds

        if [ "$STEP_STATUS" != "fail" ] || [ "$attempt" -ge "$AIDEV_RETRIES" ]; then
            STEP_RC=$rc
            break
        fi
        attempt=$((attempt + 1))
        echo "↻ $description failed (exit $rc); retrying (attempt $attempt of $AIDEV_RETRIES)..."
    done

    STEP_SECONDS=$((SECONDS - total_started))
}

# ---------------------------------------------------------------------------
# Parallel execution (--jobs N > 1). Every step runs with its output captured
# to a per-step temp file; a finished step's header, output and status line are
# printed as it completes, so overlapping runs still produce a readable log.
# ---------------------------------------------------------------------------
run_steps_parallel() {
    local n=${#selected_entries[@]}
    local tmpdir
    tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/aidev-steps.XXXXXX")" || true
    if [ -z "$tmpdir" ] || [ ! -d "$tmpdir" ]; then
        echo "❌ Could not create a temp dir for step output." >&2
        return 1
    fi
    PAR_TMPDIR="$tmpdir"

    # Per-step state, indexed by selection position.
    local -a p_pid=() p_out=() p_start=() p_total=() p_attempt=() p_used=()
    local -a live=()   # selection indices currently running

    # Launch selection index $1 in the background. The step is resolved here
    # (not taken from the global STEP_CMD, which by retry time may hold a
    # different step's argv). Each step runs inside a wrapper subshell that
    # records the step's exact exit code in '<out>.rc' when it finishes, so
    # reaping never has to guess which pid a returned status belonged to
    # (and the log tee cannot interfere). Returns 1 if the step cannot be
    # resolved (e.g. its script vanished before a retry).
    spawn_step() {
        local si="$1" kind target description
        IFS='|' read -r kind target description <<< "${selected_entries[si]}"
        resolve_step "$kind" "$target" || return 1
        p_out[si]="$tmpdir/step-$si.log"
        p_start[si]=$SECONDS
        rm -f "${p_out[si]}.rc"

        if [ "${p_attempt[si]}" -gt 1 ]; then
            printf '\n--- Retrying %s (attempt %d of %d) ---\n\n' \
                "$description" "${p_attempt[si]}" "$AIDEV_RETRIES" >> "${p_out[si]}"
        else
            : > "${p_out[si]}"
        fi

        if [ "$AIDEV_TIMEOUT" -gt 0 ] && command_exists timeout; then
            p_used[si]=1
            (
                timeout --kill-after="$AIDEV_KILL_AFTER" "$AIDEV_TIMEOUT" \
                    "${STEP_CMD[@]}" < /dev/null >> "${p_out[si]}" 2>&1
                echo $? > "${p_out[si]}.rc"
            ) 3>&- 4>&- 8>&- &
        else
            p_used[si]=0
            (
                "${STEP_CMD[@]}" < /dev/null >> "${p_out[si]}" 2>&1
                echo $? > "${p_out[si]}.rc"
            ) 3>&- 4>&- 8>&- &
        fi
        p_pid[si]=$!
        STEP_CHILDREN+=("$!")
        live+=("$si")
    }

    # Record the outcome of selection index $1 (exit code $2) and print the
    # buffered output. A failed step with attempts left is relaunched; the
    # caller has already removed the index from 'live', so a retry re-adds it
    # exactly once and job slots are never double-counted.
    finish_step() {
        local idx="$1" rc="$2"
        local seconds kind target description
        seconds=$((SECONDS - p_start[idx]))
        classify_rc "$rc" "$seconds" "${p_used[idx]}"
        RESULT_STATUS[idx]="$STEP_STATUS"
        RESULT_SECONDS[idx]=$((SECONDS - p_total[idx]))
        RESULT_RC[idx]="$rc"

        IFS='|' read -r kind target description <<< "${selected_entries[idx]}"
        if [ "$STEP_STATUS" = "fail" ] && [ "${p_attempt[idx]}" -lt "$AIDEV_RETRIES" ]; then
            p_attempt[idx]=$((p_attempt[idx] + 1))
            if spawn_step "$idx"; then
                echo "↻ $description failed (exit $rc); retrying (attempt ${p_attempt[idx]} of $AIDEV_RETRIES)..."
                return 0
            fi
            echo "⚠ $description cannot be retried: ${STEP_SKIP_REASON}"
        fi

        print_header "$description"
        [ -f "${p_out[idx]}" ] && cat "${p_out[idx]}"
        case "$STEP_STATUS" in
            ok)      echo "✓ $description completed successfully (${RESULT_SECONDS[idx]}s)" ;;
            timeout) echo "✗ $description timed out after ${seconds}s (limit ${AIDEV_TIMEOUT}s)"; failures+=("$description") ;;
            fail)    echo "✗ $description failed (exit $rc, ${RESULT_SECONDS[idx]}s)"; failures+=("$description") ;;
        esac
        return 0
    }

    # Reap every step whose wrapper has written its rc file. A finished index
    # is removed from 'live' BEFORE finish_step runs, so a retry re-adds it
    # exactly once. An rc file that exists but is still empty (write in
    # flight) counts as not finished yet. Returns 1 when nothing finished, so
    # callers can sleep between polls.
    reap_finished() {
        local ridx frc wrc i c
        local -a done_idx=() done_rc=() still_live=() kept=()
        for ridx in "${live[@]}"; do
            frc=""
            [ -f "${p_out[ridx]}.rc" ] && frc="$(<"${p_out[ridx]}".rc)"
            if [ -n "$frc" ]; then
                done_idx+=("$ridx")
                done_rc+=("$frc")
            elif ! kill -0 "${p_pid[ridx]}" 2>/dev/null; then
                # The wrapper vanished without recording an exit code: killed
                # (OOM, a stray SIGKILL) or unable to write its rc file. Fall
                # back to the wrapper's own status so a missing rc file cannot
                # wedge this poll loop forever. Testing the rc file first is
                # what makes that safe: the rc write happens before the
                # wrapper exits, so a real exit code is never lost here.
                wrc=0
                wait "${p_pid[ridx]}" 2>/dev/null || wrc=$?
                done_idx+=("$ridx")
                done_rc+=("$wrc")
            else
                still_live+=("$ridx")
            fi
        done
        [ "${#done_idx[@]}" -eq 0 ] && return 1
        live=("${still_live[@]}")
        for i in "${!done_idx[@]}"; do
            ridx="${done_idx[i]}"
            frc="${done_rc[i]}"
            wait "${p_pid[ridx]}" 2>/dev/null
            kept=()
            for c in ${STEP_CHILDREN[@]+"${STEP_CHILDREN[@]}"}; do
                [ "$c" = "${p_pid[ridx]}" ] || kept+=("$c")
            done
            STEP_CHILDREN=("${kept[@]}")
            finish_step "$ridx" "$frc"
        done
        return 0
    }

    # Poll interval for reap_finished.
    local tick=1
    [ "$FRACTIONAL_SLEEP" = 1 ] && tick="0.1"

    local i kind target description
    for ((i = 0; i < n; i++)); do
        IFS='|' read -r kind target description <<< "${selected_entries[i]}"
        if ! resolve_step "$kind" "$target"; then
            echo "⚠ $description skipped: ${STEP_SKIP_REASON}"
            RESULT_STATUS[i]="skip"
            RESULT_SECONDS[i]=0
            RESULT_RC[i]=""
            continue
        fi
        # Wait for a free slot.
        while [ "${#live[@]}" -ge "$JOBS" ]; do
            reap_finished || sleep "$tick"
        done
        p_attempt[i]=1
        p_total[i]=$SECONDS
        spawn_step "$i" || {
            echo "⚠ $description skipped: ${STEP_SKIP_REASON}"
            RESULT_STATUS[i]="skip"
            RESULT_SECONDS[i]=0
            RESULT_RC[i]=""
        }
    done

    while [ "${#live[@]}" -gt 0 ]; do
        reap_finished || sleep "$tick"
    done

    rm -rf "$tmpdir"
    PAR_TMPDIR=""
    return 0
}


# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------
RESULT_NAMES=()
RESULT_STATUS=()
RESULT_SECONDS=()
RESULT_RC=()

failures=()
skipped_count=0

if [ "$JOBS" -gt 1 ]; then
    # Names are needed up front so the summary can stay in selection order.
    for entry in "${selected_entries[@]}"; do
        IFS='|' read -r _ _ description <<< "$entry"
        RESULT_NAMES+=("$description")
    done
    if run_steps_parallel; then
        for st in "${RESULT_STATUS[@]}"; do
            [ "$st" = "skip" ] && skipped_count=$((skipped_count + 1))
        done
    else
        # Temp-dir failure: fall back to sequential execution.
        RESULT_NAMES=(); RESULT_STATUS=(); RESULT_SECONDS=(); RESULT_RC=()
        JOBS=1
    fi
fi

if [ "$JOBS" -eq 1 ]; then
    for entry in "${selected_entries[@]}"; do
        IFS='|' read -r kind target description <<< "$entry"

        print_header "$description"
        execute_step "$kind" "$target" "$description"

        RESULT_NAMES+=("$description")
        RESULT_STATUS+=("$STEP_STATUS")
        RESULT_SECONDS+=("$STEP_SECONDS")
        RESULT_RC+=("$STEP_RC")

        case "$STEP_STATUS" in
            ok)      echo "✓ $description completed successfully (${STEP_SECONDS}s)" ;;
            skip)    echo "⚠ $description skipped"; skipped_count=$((skipped_count + 1)) ;;
            timeout) echo "✗ $description timed out after ${STEP_ATTEMPT_SECONDS}s (limit ${AIDEV_TIMEOUT}s)"; failures+=("$description") ;;
            fail)    echo "✗ $description failed (exit ${STEP_RC}, ${STEP_SECONDS}s)"; failures+=("$description") ;;
        esac
    done
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
TOTAL_SECONDS=$SECONDS
echo ""
echo "====================================="
echo "Summary"
echo "====================================="

col_w=40
for name in "${RESULT_NAMES[@]}"; do
    [ "${#name}" -gt "$col_w" ] && col_w="${#name}"
done

header_fmt="%-${col_w}s %-8s %-7s %-5s\n"
printf -v dashes '%*s' "$col_w" ''
dashes="${dashes// /-}"

# The format string is built from $col_w (an integer) a few lines up, never
# from step data, so the usual printf-format warning does not apply.
summary_row() {
    # shellcheck disable=SC2059
    printf "$header_fmt" "$1" "$2" "$3" "$4"
}

summary_row "Step" "Status" "Time" "Exit"
summary_row "$dashes" "------" "----" "----"
for i in "${!RESULT_NAMES[@]}"; do
    summary_row "${RESULT_NAMES[$i]}" "${RESULT_STATUS[$i]}" "${RESULT_SECONDS[$i]}s" "${RESULT_RC[$i]:--}"
done

echo ""
printf "Started:  %s\n" "$RUN_STARTED"
printf "Finished: %s\n" "$(date '+%Y-%m-%d %H:%M:%S')"
printf "Elapsed:  %dm %ds (%ds)\n" $((TOTAL_SECONDS / 60)) $((TOTAL_SECONDS % 60)) "$TOTAL_SECONDS"
if [ -n "$LOG_FILE" ]; then
    printf "Log:      %s\n" "$LOG_FILE"
fi

echo ""
if [ ${#failures[@]} -gt 0 ]; then
    echo "====================================="
    echo "❌ ${#failures[@]} update(s) failed:"
    for f in "${failures[@]}"; do
        printf "  - %s\n" "$f"
    done
    echo "====================================="
    exit 1
fi

echo "====================================="
if [ "$skipped_count" -gt 0 ]; then
    echo "All updates completed ($skipped_count step(s) skipped)."
else
    echo "All updates completed!"
fi
echo "====================================="
