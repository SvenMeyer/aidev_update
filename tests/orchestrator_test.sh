#!/bin/bash
#
# orchestrator_test.sh - self-contained tests for aidev_update.sh.
#
# Builds a throwaway copy of the orchestrator in a temp directory, swaps in
# deterministic stub updater steps, and exercises selection, dry-run, timeouts,
# skips, logging, the concurrency lock, signal handling and the no-tee fallback.
#
# Usage: tests/orchestrator_test.sh
# Exit: 0 when every test passes, 1 otherwise.

set -u
set -o pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0

pass() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }

check_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        pass "$desc"
    else
        fail "$desc (expected '$expected', got '$actual')"
    fi
}

check_contains() {
    local desc="$1" needle="$2" file="$3"
    if grep -qF -- "$needle" "$file"; then
        pass "$desc"
    else
        fail "$desc (missing '$needle' in $file)"
    fi
}

# ---------------------------------------------------------------------------
# Build the sandbox
# ---------------------------------------------------------------------------
cp "$REPO_DIR/aidev_update.sh" "$WORK/aidev_update.sh"
chmod +x "$WORK/aidev_update.sh"

cat > "$WORK/ok.sh" <<'EOF'
#!/bin/bash
echo "ok.sh running"
exit 0
EOF

cat > "$WORK/fail.sh" <<'EOF'
#!/bin/bash
echo "fail.sh failing" >&2
exit 3
EOF

cat > "$WORK/slow.sh" <<'EOF'
#!/bin/bash
echo "slow.sh sleeping"
sleep 30
EOF

cat > "$WORK/stubborn.sh" <<'EOF'
#!/bin/bash
trap '' TERM
echo "stubborn.sh ignoring TERM"
sleep 30
EOF

cat > "$WORK/sigstep.sh" <<'EOF'
#!/bin/bash
echo "sigstep start"
sleep 300
EOF
chmod +x "$WORK"/*.sh

python3 - "$WORK/aidev_update.sh" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p).read()
new = '''STEPS=(
    "script|ok.sh|OK Step"
    "script|fail.sh|Fail Step"
    "script|slow.sh|Slow Step"
    "script|stubborn.sh|Stubborn Step"
    "script|sigstep.sh|Sig Step"
    "cmd|echo hello-from-cmd|Cmd OK Step"
    "cmd|definitely_missing_cmd --x|Missing Cmd Step"
    "script|missing_script.sh|Missing Script Step"
)'''
s, n = re.subn(r'STEPS=\(.*?\n\)', new, s, count=1, flags=re.S)
assert n == 1, "failed to patch STEPS"
open(p, 'w').write(s)
PY

# Run the sandboxed orchestrator from $WORK, propagating env vars.
run() { ( cd "$WORK" && "$@" ); }

# Start the sandboxed orchestrator in the background and set BG_PID to its
# PID. 'exec' replaces the subshell so the PID is the orchestrator itself,
# letting us signal and wait for it directly.
BG_PID=""
start_bg() {
    ( cd "$WORK" && exec "$@" ) > "$WORK/bg.out" 2>&1 &
    BG_PID=$!
}

echo "== basic options =="
run bash aidev_update.sh --help > "$WORK/help.out" 2>&1
check_eq "--help exits 0" 0 "$?"
check_contains "--help documents --dry-run" "--dry-run" "$WORK/help.out"

run bash aidev_update.sh --list > "$WORK/list.out" 2>&1
check_eq "--list exits 0" 0 "$?"
check_contains "--list shows an enabled step" "OK Step" "$WORK/list.out"
check_contains "--list shows a disabled step" "Disabled steps:" "$WORK/list.out"

run bash aidev_update.sh --only nomatchxyz > "$WORK/nomatch.out" 2>&1
check_eq "no-match exits 2" 2 "$?"

echo "== dry run =="
run bash aidev_update.sh --dry-run > "$WORK/dry.out" 2>&1
check_eq "--dry-run exits 0" 0 "$?"
check_contains "--dry-run reports would-run" "[would run]" "$WORK/dry.out"
check_contains "--dry-run reports skip" "command not found" "$WORK/dry.out"

echo "== full run =="
run env AIDEV_TIMEOUT=1 AIDEV_KILL_AFTER=1 timeout 60 \
    bash aidev_update.sh > "$WORK/run.out" 2>&1
check_eq "full run exits 1 when steps fail" 1 "$?"

check_contains "ok step completed" "✓ OK Step completed successfully" "$WORK/run.out"
check_contains "fail step reported" "✗ Fail Step failed" "$WORK/run.out"
check_contains "slow step timed out" "✗ Slow Step timed out" "$WORK/run.out"
check_contains "stubborn step timed out" "✗ Stubborn Step timed out" "$WORK/run.out"
check_contains "cmd step ran" "hello-from-cmd" "$WORK/run.out"
check_contains "missing cmd skipped" "command not found: definitely_missing_cmd" "$WORK/run.out"
check_contains "missing script skipped" "script not found: missing_script.sh" "$WORK/run.out"

# Skipped steps must not inherit a previous step's duration.
skip_line=$(grep 'Missing Cmd Step' "$WORK/run.out" | grep -E ' +skip +' || true)
if printf '%s' "$skip_line" | grep -qE 'skip +0s'; then
    pass "skipped step reports 0s"
else
    fail "skipped step reports 0s (got: $skip_line)"
fi

last_log=$(find "$WORK/logs" -maxdepth 1 -type f -name 'aidev-*.log' 2>/dev/null | sort | tail -1)
if [ -n "$last_log" ] && grep -qF "Summary" "$last_log"; then
    pass "run log created and populated"
else
    fail "run log created and populated"
fi

echo "== logging disabled =="
run env AIDEV_NO_LOG=1 timeout 60 bash aidev_update.sh --only ok.sh \
    > "$WORK/nolog.out" 2>&1
if grep -qF "Log file:" "$WORK/nolog.out"; then
    fail "AIDEV_NO_LOG=1 suppresses log line"
else
    pass "AIDEV_NO_LOG=1 suppresses log line"
fi

echo "== concurrency lock =="
start_bg env AIDEV_TIMEOUT=30 bash aidev_update.sh --only "Sig Step"
first=$BG_PID
sleep 1
run bash aidev_update.sh --only "OK Step" > "$WORK/lock2.out" 2>&1
check_eq "second concurrent run exits 1" 1 "$?"
check_contains "second run names the lock" "in progress" "$WORK/lock2.out"
kill -TERM "$first" 2>/dev/null
for _ in $(seq 1 100); do kill -0 "$first" 2>/dev/null || break; sleep 0.1; done
kill -9 "$first" 2>/dev/null
wait "$first" 2>/dev/null
for p in $(pgrep -f '[s]igstep\.sh'); do kill -9 "$p" 2>/dev/null; done

echo "== signal handling =="
start_bg env AIDEV_TIMEOUT=120 AIDEV_KILL_AFTER=2 bash aidev_update.sh --only "Sig Step"
orch=$BG_PID
sleep 1
kill -TERM "$orch"
for _ in $(seq 1 100); do kill -0 "$orch" 2>/dev/null || break; sleep 0.1; done
if kill -0 "$orch" 2>/dev/null; then
    fail "SIGTERM terminates the orchestrator"
    kill -9 "$orch" 2>/dev/null
else
    wait "$orch" 2>/dev/null
    check_eq "SIGTERM exit code is 130" 130 "$?"
fi
for p in $(pgrep -f '[s]igstep\.sh'); do kill -9 "$p" 2>/dev/null; done

echo "== no tee fallback =="
FAKE_BIN="$WORK/fakebin"
mkdir -p "$FAKE_BIN"
for b in dirname date mkdir rm find timeout sleep kill flock npm curl mkfifo bash cat awk sed grep; do
    src="$(command -v "$b" 2>/dev/null)" && ln -sf "$src" "$FAKE_BIN/$b"
done
rm -f "$FAKE_BIN/tee"
PATH="$FAKE_BIN" timeout 20 bash "$WORK/aidev_update.sh" --only ok.sh \
    > "$WORK/notee.out" 2>&1
rc=$?
check_eq "missing-tee run exits cleanly" 0 "$rc"
check_contains "missing-tee warns about disabled logging" "logging disabled" "$WORK/notee.out"

echo ""
echo "====================================="
echo "Tests passed: $PASS  failed: $FAIL"
echo "====================================="
[ "$FAIL" -eq 0 ]
