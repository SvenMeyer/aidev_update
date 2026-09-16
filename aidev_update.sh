#!/bin/bash
#
# aidev_update.sh - update orchestrator for AI dev CLI tools.
#
# Runs a configurable list of updater steps in sequence. Every step is executed
# even if an earlier one fails; a summary is printed at the end and the script
# exits non-zero if any step failed.
#
# Run './aidev_update.sh --help' for usage, options, environment variables and
# examples. Full documentation lives in README.md.

# Note: we deliberately do not use 'set -e' so a single failing update does not
# abort the rest of the run. Failures are collected and reported instead.
set -u
set -o pipefail

# Directory where this script lives.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

AIDEV_TIMEOUT="${AIDEV_TIMEOUT:-600}"
if ! [[ "$AIDEV_TIMEOUT" =~ ^[0-9]+$ ]]; then
    echo "⚠ AIDEV_TIMEOUT must be a whole number of seconds; using 600." >&2
    AIDEV_TIMEOUT=600
fi

# Seconds to wait after SIGTERM before killing a hung step, and the predicate
# used to classify a step as timed out (124 = SIGTERM, 137 = SIGKILL).
AIDEV_KILL_AFTER="${AIDEV_KILL_AFTER:-10}"
if ! [[ "$AIDEV_KILL_AFTER" =~ ^[0-9]+$ ]]; then
    echo "⚠ AIDEV_KILL_AFTER must be a whole number of seconds; using 10." >&2
    AIDEV_KILL_AFTER=10
fi

AIDEV_LOG_RETENTION_DAYS="${AIDEV_LOG_RETENTION_DAYS:-30}"
if ! [[ "$AIDEV_LOG_RETENTION_DAYS" =~ ^[0-9]+$ ]]; then
    echo "⚠ AIDEV_LOG_RETENTION_DAYS must be a whole number of days; using 30." >&2
    AIDEV_LOG_RETENTION_DAYS=30
fi

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
  --dry-run         Show which steps would run (and which would be skipped),
                    then exit without updating anything.
  --list            List configured steps and exit.
  -h, --help        Show this help.

Environment:
  AIDEV_TIMEOUT              Per-step timeout in seconds (default: 600).
  AIDEV_KILL_AFTER           Grace period after SIGTERM before SIGKILL
                             (default: 10).
  AIDEV_LOG_DIR              Directory for run logs (default: <script dir>/logs).
  AIDEV_LOG_RETENTION_DAYS   Delete run logs older than this many days
                             (default: 30; 0 disables pruning).
  AIDEV_NO_LOG               Set to 1 to disable logging.

Examples:
  aidev_update.sh                     # run everything
  aidev_update.sh --only grok         # just the Grok updater
  aidev_update.sh --skip gastown      # everything except Gastown
  aidev_update.sh --dry-run           # show what would happen
  AIDEV_TIMEOUT=120 aidev_update.sh   # 2 minute cap per step
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
wait_for_pid() {
    local pid="$1" limit="${2:-5}"
    local ticks=$((limit * 10))
    local i=0
    while kill -0 "$pid" 2>/dev/null; do
        [ "$i" -ge "$ticks" ] && return 1
        sleep 0.1
        i=$((i + 1))
    done
    return 0
}

# Globals set by resolve_step.
STEP_CMD=()
STEP_SKIP_REASON=""

# Resolve a step into a runnable argv in STEP_CMD. Returns 0 if it can run, or
# 1 (with STEP_SKIP_REASON set) if it should be skipped. Shared by the preflight
# pass, --dry-run and execute_step so the availability rules live in one place.
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
        IFS='|' read -r _ target description <<< "$entry"
        printf '  %-28s %s\n' "$target" "$description"
    done
    echo ""
    echo "Disabled steps:"
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
        else
            printf '  [skip]      %-40s (%s)\n' "$description" "$STEP_SKIP_REASON"
        fi
    done
    exit 0
fi

# ---------------------------------------------------------------------------
# Concurrency guard: a second run would race the package managers.
# ---------------------------------------------------------------------------
LOCK_FILE=""
if command_exists flock; then
    LOCK_FILE="$SCRIPT_DIR/.aidev_update.lock"
    exec 8>"$LOCK_FILE"
    if ! flock -n 8; then
        echo "❌ Another aidev_update.sh run is in progress (lock: $LOCK_FILE)." >&2
        exit 1
    fi
fi

# ---------------------------------------------------------------------------
# Signal handling: forward termination to the running step, then exit via the
# normal EXIT trap so logging is still cleaned up.
# ---------------------------------------------------------------------------
STEP_CHILD=""
on_signal() {
    if [ -n "$STEP_CHILD" ]; then
        kill "$STEP_CHILD" 2>/dev/null
        # Bound the wait: a step that ignores SIGTERM must not block Ctrl-C.
        if ! wait_for_pid "$STEP_CHILD" "$AIDEV_KILL_AFTER"; then
            kill -9 "$STEP_CHILD" 2>/dev/null
            wait_for_pid "$STEP_CHILD" 2
        fi
        wait "$STEP_CHILD" 2>/dev/null
        STEP_CHILD=""
    fi
    exit 130
}
trap on_signal INT TERM

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
trap cleanup_logging EXIT

prune_logs() {
    local dir="$1" days="$2"
    [ "$days" -gt 0 ] || return 0
    command_exists find || return 0
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
# Run one step. Sets STEP_STATUS to ok|fail|timeout|skip and STEP_SECONDS.
# ---------------------------------------------------------------------------
execute_step() {
    local kind="$1"
    local target="$2"

    STEP_STATUS=""
    STEP_SECONDS=0

    if ! resolve_step "$kind" "$target"; then
        echo "⚠ ${STEP_SKIP_REASON}"
        STEP_STATUS="skip"
        return
    fi

    local started=$SECONDS
    local rc=0

    if command_exists timeout; then
        timeout --kill-after="$AIDEV_KILL_AFTER" "$AIDEV_TIMEOUT" \
            "${STEP_CMD[@]}" &
    else
        "${STEP_CMD[@]}" &
    fi
    STEP_CHILD=$!
    wait "$STEP_CHILD" || rc=$?
    STEP_CHILD=""

    STEP_SECONDS=$((SECONDS - started))

    if [ "$rc" -eq 0 ]; then
        STEP_STATUS="ok"
    elif [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
        STEP_STATUS="timeout"
    else
        STEP_STATUS="fail"
    fi
}

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------
RESULT_NAMES=()
RESULT_STATUS=()
RESULT_SECONDS=()

failures=()
skipped_count=0

for entry in "${selected_entries[@]}"; do
    IFS='|' read -r kind target description <<< "$entry"

    print_header "$description"
    execute_step "$kind" "$target"

    RESULT_NAMES+=("$description")
    RESULT_STATUS+=("$STEP_STATUS")
    RESULT_SECONDS+=("$STEP_SECONDS")

    case "$STEP_STATUS" in
        ok)      echo "✓ $description completed successfully (${STEP_SECONDS}s)" ;;
        skip)    echo "⚠ $description skipped"; skipped_count=$((skipped_count + 1)) ;;
        timeout) echo "✗ $description timed out after ${AIDEV_TIMEOUT}s"; failures+=("$description") ;;
        fail)    echo "✗ $description failed (${STEP_SECONDS}s)"; failures+=("$description") ;;
    esac
done

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "====================================="
echo "Summary"
echo "====================================="
printf '%-40s %-8s %s\n' "Step" "Status" "Time"
printf '%-40s %-8s %s\n' "----" "------" "----"
for i in "${!RESULT_NAMES[@]}"; do
    printf '%-40s %-8s %ss\n' "${RESULT_NAMES[$i]}" "${RESULT_STATUS[$i]}" "${RESULT_SECONDS[$i]}"
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
