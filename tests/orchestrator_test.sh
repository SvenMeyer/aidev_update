#!/bin/bash
#
# orchestrator_test.sh - self-contained tests for aidev_update.sh.
#
# Builds a throwaway copy of the orchestrator in a temp directory, swaps in
# deterministic stub updater steps, and exercises selection, dry-run, timeouts,
# exit-code classification, retries, parallel runs (--jobs), skips, logging,
# the concurrency lock, signal handling and the no-tee/no-timeout fallbacks.
#
# Usage: tests/orchestrator_test.sh
# Exit: 0 when every test passes, 1 otherwise.

set -u
set -o pipefail
# Job control on: without it, bash ignores SIGINT in background children,
# which would make the SIGINT test impossible to exercise.
set -m

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'chmod -R u+w "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT

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

check_absent() {
    local desc="$1" needle="$2" file="$3"
    if grep -qF -- "$needle" "$file"; then
        fail "$desc (unexpected '$needle' in $file)"
    else
        pass "$desc"
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

# Exits 124 on its own: must be reported as a failure, not a timeout.
cat > "$WORK/exit124.sh" <<'EOF'
#!/bin/bash
echo "exit124.sh exiting with its own 124"
exit 124
EOF

# Fails on the first attempt, succeeds afterwards (marker file in cwd).
cat > "$WORK/flaky.sh" <<'EOF'
#!/bin/bash
if [ -f flaky.marker ]; then
    echo "flaky.sh ok on retry"
    exit 0
fi
touch flaky.marker
echo "flaky.sh first attempt fails"
exit 7
EOF

# Gate steps succeed only when the other gate has run: with --jobs 2 both
# finish quickly, sequentially the first one times out.
cat > "$WORK/gate_a.sh" <<'EOF'
#!/bin/bash
touch gate-a.marker
i=0
while [ ! -f gate-b.marker ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
if [ -f gate-b.marker ]; then echo "gate a met gate b"; exit 0; fi
echo "gate a gave up"; exit 1
EOF

cat > "$WORK/gate_b.sh" <<'EOF'
#!/bin/bash
touch gate-b.marker
i=0
while [ ! -f gate-a.marker ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
if [ -f gate-a.marker ]; then echo "gate b met gate a"; exit 0; fi
echo "gate b gave up"; exit 1
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
    "script|exit124.sh|Exit 124 Step"
    "script|flaky.sh|Flaky Step"
    "script|gate_a.sh|Gate A Step"
    "script|gate_b.sh|Gate B Step"
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
check_contains "--help documents --jobs" "--jobs" "$WORK/help.out"

run bash aidev_update.sh --list > "$WORK/list.out" 2>&1
check_eq "--list exits 0" 0 "$?"
check_contains "--list shows an enabled step" "OK Step" "$WORK/list.out"
check_contains "--list shows a disabled step" "Disabled steps" "$WORK/list.out"
check_contains "--list shows availability" "[runnable]" "$WORK/list.out"
check_contains "--list shows skip reason" "script not found" "$WORK/list.out"

run bash aidev_update.sh --only nomatchxyz > "$WORK/nomatch.out" 2>&1
check_eq "no-match exits 2" 2 "$?"

run bash aidev_update.sh --jobs 0 > "$WORK/badjobs.out" 2>&1
check_eq "--jobs 0 rejected" 2 "$?"

echo "== dry run =="
run bash aidev_update.sh --dry-run > "$WORK/dry.out" 2>&1
check_eq "--dry-run exits 0" 0 "$?"
check_contains "--dry-run reports would-run" "[would run]" "$WORK/dry.out"
check_contains "--dry-run reports skip" "command not found" "$WORK/dry.out"
check_contains "--dry-run shows resolved argv" "argv: bash" "$WORK/dry.out"

echo "== full sequential run =="
run env AIDEV_TIMEOUT=1 AIDEV_KILL_AFTER=1 timeout 90 \
    bash aidev_update.sh > "$WORK/run.out" 2>&1
check_eq "full run exits 1 when steps fail" 1 "$?"

check_contains "ok step completed" "✓ OK Step completed successfully" "$WORK/run.out"
check_contains "fail step reported with exit code" "✗ Fail Step failed (exit 3" "$WORK/run.out"
check_contains "slow step timed out" "✗ Slow Step timed out" "$WORK/run.out"
check_contains "stubborn step timed out" "✗ Stubborn Step timed out" "$WORK/run.out"
check_contains "own-124 reported as failure" "✗ Exit 124 Step failed (exit 124" "$WORK/run.out"
check_absent  "own-124 not called a timeout" "Exit 124 Step timed out" "$WORK/run.out"
check_contains "cmd step ran" "hello-from-cmd" "$WORK/run.out"
check_contains "missing cmd skipped" "command not found: definitely_missing_cmd" "$WORK/run.out"
check_contains "missing script skipped" "script not found: missing_script.sh" "$WORK/run.out"
# Sequential proof: gate A runs first, waits for gate B and times out;
# gate B then finds gate A's marker and succeeds.
check_contains "gate a serialized (timed out)" "✗ Gate A Step timed out" "$WORK/run.out"
check_contains "gate b ran after gate a" "✓ Gate B Step completed successfully" "$WORK/run.out"

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

echo "== retries =="
rm -f "$WORK/flaky.marker"
run env AIDEV_TIMEOUT=10 timeout 60 bash aidev_update.sh --only flaky.sh \
    > "$WORK/retry1.out" 2>&1
check_eq "single attempt fails" 1 "$?"
if grep -qF "retrying" "$WORK/retry1.out"; then
    fail "no retry attempted with AIDEV_RETRIES=1"
else
    pass "no retry attempted with AIDEV_RETRIES=1"
fi
check_contains "flaky failed on first attempt" "✗ Flaky Step failed (exit 7" "$WORK/retry1.out"

rm -f "$WORK/flaky.marker"
run env AIDEV_TIMEOUT=10 AIDEV_RETRIES=2 timeout 60 \
    bash aidev_update.sh --only flaky.sh > "$WORK/retry2.out" 2>&1
check_eq "retry run succeeds" 0 "$?"
check_contains "retry announced" "retrying (attempt 2 of 2)" "$WORK/retry2.out"
check_contains "retry succeeded" "✓ Flaky Step completed successfully" "$WORK/retry2.out"

echo "== parallel run (--jobs 2) =="
rm -f "$WORK"/gate-*.marker
run env AIDEV_TIMEOUT=10 timeout 60 bash aidev_update.sh --jobs 2 --only Gate \
    > "$WORK/par.out" 2>&1
check_eq "parallel gate run exits 0" 0 "$?"
check_contains "gate a completed in parallel" "✓ Gate A Step completed successfully" "$WORK/par.out"
check_contains "gate b completed in parallel" "✓ Gate B Step completed successfully" "$WORK/par.out"

rm -f "$WORK/flaky.marker"
run env AIDEV_TIMEOUT=10 timeout 60 bash aidev_update.sh --jobs 2 --only flaky.sh \
    > "$WORK/parfail.out" 2>&1
check_eq "parallel failing step exits 1" 1 "$?"
check_contains "parallel failure reported with exit code" \
    "✗ Flaky Step failed (exit 7" "$WORK/parfail.out"

rm -f "$WORK"/gate-*.marker
run env AIDEV_TIMEOUT=10 timeout 60 bash aidev_update.sh --jobs 3 --only "Gate" \
    > "$WORK/par3.out" 2>&1
check_eq "--jobs 3 gate run exits 0" 0 "$?"
check_contains "parallel summary keeps all steps" "Gate B Step" "$WORK/par3.out"

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

echo "== lock in read-only directory =="
RO="$WORK/readonly"
mkdir -p "$RO"
cp "$WORK/aidev_update.sh" "$RO/aidev_update.sh"
cp "$WORK/ok.sh" "$RO/ok.sh"
chmod 555 "$RO"
run bash "$RO/aidev_update.sh" --only ok.sh > "$WORK/rolock.out" 2>&1
check_eq "read-only lock dir does not abort" 0 "$?"
check_contains "read-only lock dir warns" "without a concurrency guard" "$WORK/rolock.out"
chmod 755 "$RO"

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
    check_eq "SIGTERM exit code is 143" 143 "$?"
fi
for p in $(pgrep -f '[s]igstep\.sh'); do kill -9 "$p" 2>/dev/null; done

start_bg env AIDEV_TIMEOUT=120 AIDEV_KILL_AFTER=2 bash aidev_update.sh --only "Sig Step"
orch=$BG_PID
sleep 1
kill -INT "$orch"
for _ in $(seq 1 100); do kill -0 "$orch" 2>/dev/null || break; sleep 0.1; done
if kill -0 "$orch" 2>/dev/null; then
    fail "SIGINT terminates the orchestrator"
    kill -9 "$orch" 2>/dev/null
else
    wait "$orch" 2>/dev/null
    check_eq "SIGINT exit code is 130" 130 "$?"
fi
for p in $(pgrep -f '[s]igstep\.sh'); do kill -9 "$p" 2>/dev/null; done

echo "== no tee fallback =="
FAKE_BIN="$WORK/fakebin"
mkdir -p "$FAKE_BIN"
for b in dirname date mkdir rm find timeout sleep kill flock npm curl mkfifo bash cat awk sed grep; do
    src="$(command -v "$b" 2>/dev/null)" && ln -sf "$src" "$FAKE_BIN/$b"
done
rm -f "$FAKE_BIN/tee"
timeout 20 env PATH="$FAKE_BIN" bash "$WORK/aidev_update.sh" --only ok.sh \
    > "$WORK/notee.out" 2>&1
rc=$?
check_eq "missing-tee run exits cleanly" 0 "$rc"
check_contains "missing-tee warns about disabled logging" "logging disabled" "$WORK/notee.out"

echo "== no timeout binary fallback =="
FAKE_BIN2="$WORK/fakebin2"
mkdir -p "$FAKE_BIN2"
for b in dirname date mkdir rm find sleep kill flock npm curl mkfifo bash cat awk sed grep tee pgrep; do
    src="$(command -v "$b" 2>/dev/null)" && ln -sf "$src" "$FAKE_BIN2/$b"
done
rm -f "$FAKE_BIN2/timeout"
timeout 20 env PATH="$FAKE_BIN2" AIDEV_TIMEOUT=5 \
    bash "$WORK/aidev_update.sh" --only "Exit 124" > "$WORK/notimeout.out" 2>&1
rc=$?
check_eq "missing-timeout run reports failure" 1 "$rc"
check_contains "own-124 classified as fail without timeout(1)" \
    "✗ Exit 124 Step failed (exit 124" "$WORK/notimeout.out"
check_absent "no bogus timeout claim without timeout(1)" \
    "Exit 124 Step timed out" "$WORK/notimeout.out"

echo ""
echo "====================================="
echo "Tests passed: $PASS  failed: $FAIL"
echo "====================================="
[ "$FAIL" -eq 0 ]
