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
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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
# validate_env right before logging starts, so misconfiguration warnings are
# captured in the run log as well as on the terminal.
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
)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

usage() {
    cat <<'EOF'
Usage: aidev_update.sh [options] [name ...]

Options:
  --only PATTERN    Run only steps whose target/description matches PATTERN.
                    Repeatable. A bare positional name is treated as --only.
  --skip PATTERN    Skip steps whose target/description matches PATTERN.
  --jobs N          Run up to N steps at the same time (default: 1). Each
                    step's output is buffered and printed when the step
                    finishes, so parallel runs stay readable.
  --dry-run         Show which steps would run (and which would be skipped),
                    then exit without updating anything.
  --list            List configured steps and their current availability.
  -h, --help        Show this help.

Notes:
  - PATTERN matching is a case-insensitive substring test against both the
    step target and its description, so a broad pattern like 'update' or
    'open' can match several steps at once.
  - 'cmd' steps are split on whitespace only: no quoting, escapes or paths
    with spaces. Use a small wrapper script for those.

Environment:
  AIDEV_TIMEOUT              Per-step timeout in seconds (default: 600).
                             0 disables the timeout entirely.
  AIDEV_KILL_AFTER           Grace period after SIGTERM before SIGKILL
                             (default: 10).
  AIDEV_RETRIES              Attempts per failed step (default: 1, i.e. no
                             retry). Only non-zero exits are retried.
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
  AIDEV_TIMEOUT=120 aidev_update.sh   # 2 minute cap per step
  AIDEV_RETRIES=2 aidev_update.sh      # one extra try on failure
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
# Note: this only sees processes that are still unreaped; it is not used to
# detect job completion (zombies still answer 'kill -0'), only to bound waits.
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
STEP_STATUS=""
STEP_SECONDS=0
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
    else
        if [ ! -f "$SCRIPT_DIR/$target" ]; then
            STEP_SKIP_REASON="script not found: $target"
            return 1
        fi
        STEP_CMD=(bash "$SCRIPT_DIR/$target")
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

while [ $# -gt 0 ]; do
    case "$1" in
        --only)
            shift
            if [ $# -eq 0 ]; then echo "Missing value for --only" >&2; exit 2; fi
            ONLY_PATTERNS+=("$1")
            ;;
        --only=*) ONLY_PATTERNS+=("${1#*=}") ;;
        --skip)
            shift
            if [ $# -eq 0 ]; then echo "Missing value for --skip" >&2; exit 2; fi
            SKIP_PATTERNS+=("$1")
            ;;
        --skip=*) SKIP_PATTERNS+=("${1#*=}") ;;
        --jobs)
            shift
            if [ $# -eq 0 ]; then echo "Missing value for --jobs" >&2; exit 2; fi
            if ! [[ "$1" =~ ^[0-9]+$ ]] || [ "$1" -lt 1 ]; then
                echo "--jobs must be a positive whole number" >&2
                exit 2
            fi
            JOBS="$1"
            ;;
        --jobs=*)
            if ! [[ "${1#*=}" =~ ^[0-9]+$ ]] || [ "${1#*=}" -lt 1 ]; then
                echo "--jobs must be a positive whole number" >&2
                exit 2
            fi
            JOBS="${1#*=}"
            ;;
        --dry-run) DRY_RUN=1 ;;
        --list) LIST_ONLY=1 ;;
        -h|--help) usage; exit 0 ;;
        -*)
            echo "Unknown option: $1" >&2
            echo "Run '$(basename "$0") --help' for usage." >&2
            exit 2
            ;;
        *) ONLY_PATTERNS+=("$1") ;;
    esac
    shift
done

if [ "$LIST_ONLY" -eq 1 ]; then
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
    echo ""
    echo "Disabled steps (kept for reference; move a line into STEPS to enable):"
    for entry in "${DISABLED_STEPS[@]}"; do
        IFS='|' read -r _ target description <<< "$entry"
        printf '  %-28s %s\n' "$target" "$description"
    done
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
            : # Lock acquired; fd 8 is held until the script exits.
        else
            echo "❌ Another aidev_update.sh run is in progress (lock: $LOCK_FILE)." >&2
            exit 1
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
    if [ "${#STEP_CHILDREN[@]}" -gt 0 ]; then
        for pid in "${STEP_CHILDREN[@]}"; do
            kill_tree "$pid" TERM
            # Bound the wait: a step that ignores SIGTERM must not block Ctrl-C.
            if ! wait_for_pid "$pid" "$AIDEV_KILL_AFTER"; then
                kill_tree "$pid" 9
                wait_for_pid "$pid" 2
            fi
            wait "$pid" 2>/dev/null
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
    exit "$code"
}
trap 'on_signal 130' INT
trap 'on_signal 143' TERM

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

cleanup_logging() {
    if [ -n "$LOG_FIFO" ]; then
        # Close our write end so tee sees EOF.
        exec 1>&- 2>&-
        if [ -n "$TEE_PID" ]; then
            # An orphaned grandchild may still hold the pipe open; never block
            # the run forever waiting for tee.
            if ! wait_for_pid "$TEE_PID" 5; then
                kill "$TEE_PID" 2>/dev/null
                wait_for_pid "$TEE_PID" 2
            fi
            wait "$TEE_PID" 2>/dev/null
        fi
        [ -p "$LOG_FIFO" ] && rm -f "$LOG_FIFO"
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
    [ "$days" -gt 0 ] || return 0
    if ! command_exists find; then
        echo "⚠ 'find' not found; log pruning disabled." >&2
        return 0
    fi
    find "$dir" -maxdepth 1 -type f -name 'aidev-*.log' \
        -mtime +"$days" -delete 2>/dev/null || true
}

# Sanitize tunables before anything consumes them (prune_logs reads
# AIDEV_LOG_RETENTION_DAYS below); warnings are replayed once logging is up.
validate_env

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
                exec > "$LOG_FIFO" 2>&1
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
echo "AEDev update run started: $RUN_STARTED"
if [ -n "$LOG_FILE" ]; then
    echo "Log file: $LOG_FILE"
fi

# ---------------------------------------------------------------------------
# Core dependency check
# ---------------------------------------------------------------------------
echo ""
echo "Checking dependencies..."
missing_deps=()
for dep in npm curl; do
    command_exists "$dep" || missing_deps+=("$dep")
done

if [ ${#missing_deps[@]} -ne 0 ]; then
    echo "❌ Missing required dependencies: ${missing_deps[*]}"
    echo "Please install the missing dependencies and try again."
    exit 1
fi
echo "✓ All dependencies found"

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
                "${STEP_CMD[@]}" 8>&- &
        else
            "${STEP_CMD[@]}" 8>&- &
        fi
        STEP_CHILDREN=($!)
        wait "${STEP_CHILDREN[0]}" || rc=$?
        STEP_CHILDREN=()

        classify_rc "$rc" "$((SECONDS - started))" "$used_timeout"

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
        if [ "$AIDEV_TIMEOUT" -gt 0 ] && command_exists timeout; then
            p_used[si]=1
            (
                timeout --kill-after="$AIDEV_KILL_AFTER" "$AIDEV_TIMEOUT" \
                    "${STEP_CMD[@]}" > "${p_out[si]}" 2>&1
                echo $? > "${p_out[si]}.rc"
            ) 8>&- &
        else
            p_used[si]=0
            (
                "${STEP_CMD[@]}" > "${p_out[si]}" 2>&1
                echo $? > "${p_out[si]}.rc"
            ) 8>&- &
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
            if spawn_step "$idx"; then
                p_attempt[idx]=$((p_attempt[idx] + 1))
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
        local ridx frc i c
        local -a done_idx=() done_rc=() still_live=() kept=()
        for ridx in "${live[@]}"; do
            frc=""
            [ -f "${p_out[ridx]}.rc" ] && frc="$(<"${p_out[ridx]}".rc)"
            if [ -n "$frc" ]; then
                done_idx+=("$ridx")
                done_rc+=("$frc")
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
            echo "⚠ ${STEP_SKIP_REASON}"
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
            echo "⚠ ${STEP_SKIP_REASON}"
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
            timeout) echo "✗ $description timed out after ${STEP_SECONDS}s (limit ${AIDEV_TIMEOUT}s)"; failures+=("$description") ;;
            fail)    echo "✗ $description failed (exit ${STEP_RC}, ${STEP_SECONDS}s)"; failures+=("$description") ;;
        esac
    done
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "====================================="
echo "Summary"
echo "====================================="
printf '%-40s %-8s %-7s %-5s\n' "Step" "Status" "Time" "Exit"
printf '%-40s %-8s %-7s %-5s\n' "----" "------" "----" "----"
for i in "${!RESULT_NAMES[@]}"; do
    printf '%-40s %-8s %-7s %-5s\n' "${RESULT_NAMES[$i]}" "${RESULT_STATUS[$i]}" "${RESULT_SECONDS[$i]}s" "${RESULT_RC[$i]:--}"
done

echo ""
echo "Started:  $RUN_STARTED"
echo "Finished: $(date '+%Y-%m-%d %H:%M:%S')"
if [ -n "$LOG_FILE" ]; then
    echo "Log:      $LOG_FILE"
fi

echo ""
if [ ${#failures[@]} -gt 0 ]; then
    echo "====================================="
    echo "❌ ${#failures[@]} update(s) failed: ${failures[*]}"
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
