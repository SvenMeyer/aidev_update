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
SKIP=0

pass() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }
skip() { echo "  - $1 (skipped)"; SKIP=$((SKIP + 1)); }

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

# Two steps that finish at (nearly) the same instant with distinct exit codes:
# parallel reaping must attribute each code to the right step.
cat > "$WORK/twin_a.sh" <<'EOF'
#!/bin/bash
sleep 1
exit 10
EOF

cat > "$WORK/twin_b.sh" <<'EOF'
#!/bin/bash
sleep 1
exit 20
EOF

# A step with a background grandchild: signals must clean up the whole tree.
cat > "$WORK/treestep.sh" <<'EOF'
#!/bin/bash
sleep 300 &
echo $! > tree-child.pid
wait
EOF

# Fails instantly on the first attempt; the successful retry takes 12s.
# Reaped correctly, the summary must show ~12s total for this step; a reaper
# that double-counts retried steps finishes the stale entry early (with
# another step's exit code) and reports only ~1s.
cat > "$WORK/retry_slow.sh" <<'EOF'
#!/bin/bash
if [ -f retry_slow.marker ]; then
    echo "retry_slow ok on long retry"
    sleep 12
    exit 0
fi
touch retry_slow.marker
echo "retry_slow failing fast"
exit 7
EOF

# A quiet 1s step used as the reaping partner of retry_slow.sh.
cat > "$WORK/wait_a_bit.sh" <<'EOF'
#!/bin/bash
sleep 1
exit 0
EOF

# Long-running step whose wrapper subshell is SIGKILLed mid-run by the
# killed-wrapper test: the wrapper never gets to record an exit code.
cat > "$WORK/killable.sh" <<'EOF'
#!/bin/bash
echo "killable.sh running"
sleep 20
EOF

# Fails if it inherits the orchestrator's lock descriptor.
cat > "$WORK/fdcheck.sh" <<'EOF'
#!/bin/bash
for fd in /proc/$$/fd/*; do
    case "$(readlink "$fd" 2>/dev/null)" in
        *".aidev_update.lock")
            echo "lock fd leaked into step"
            exit 1
            ;;
    esac
done
echo "no lock fd leak"
exit 0
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
    "script|twin_a.sh|Twin A Step"
    "script|twin_b.sh|Twin B Step"
    "script|treestep.sh|Tree Step"
    "script|retry_slow.sh|Retry Slow Step"
    "script|wait_a_bit.sh|Wait A Bit Step"
    "script|fdcheck.sh|Fd Check Step"
    "script|killable.sh|Killable Step"
    "bogus|ok.sh|Bogus Kind Step"
    "cmd|echo hello-from-cmd|Cmd OK Step"
    "sh|echo hello-from-sh 'with spaces'|Sh OK Step"
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
run bash aidev_update.sh --version > "$WORK/ver.out" 2>&1
check_eq "--version exits 0" 0 "$?"
check_contains "--version outputs v1.4.0" "v1.4.0" "$WORK/ver.out"

run bash aidev_update.sh -v > "$WORK/ver_short.out" 2>&1
check_eq "-v exits 0" 0 "$?"
check_contains "-v outputs v1.4.0" "v1.4.0" "$WORK/ver_short.out"

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
check_contains "no-match lists available steps" "Available steps" "$WORK/nomatch.out"

run bash aidev_update.sh --jobs 0 > "$WORK/badjobs.out" 2>&1
check_eq "--jobs 0 rejected" 2 "$?"

run bash aidev_update.sh --timeout abc > "$WORK/badtimeout.out" 2>&1
check_eq "--timeout abc rejected" 2 "$?"

run bash aidev_update.sh --retries 0 > "$WORK/badretries.out" 2>&1
check_eq "--retries 0 rejected" 2 "$?"

run bash aidev_update.sh --only "" > "$WORK/emptyonly.out" 2>&1
check_eq "empty --only rejected" 2 "$?"

run bash aidev_update.sh --skip "" > "$WORK/emptyskip.out" 2>&1
check_eq "empty --skip rejected" 2 "$?"

run bash aidev_update.sh -t 120 -r 2 --dry-run -- "OK Step" > "$WORK/clitunables.out" 2>&1
check_eq "cli tunables and dashdash accepted" 0 "$?"

echo "== dry run =="
run bash aidev_update.sh --dry-run > "$WORK/dry.out" 2>&1
check_eq "--dry-run exits 0" 0 "$?"
check_contains "--dry-run reports would-run" "[would run]" "$WORK/dry.out"
check_contains "--dry-run reports skip" "command not found" "$WORK/dry.out"
check_contains "--dry-run shows resolved argv" "argv: bash" "$WORK/dry.out"
check_contains "--dry-run shows sh argv" "argv: bash -c echo hello-from-sh" "$WORK/dry.out"

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
check_contains "sh step ran" "hello-from-sh with spaces" "$WORK/run.out"
check_contains "missing cmd skipped" "command not found: definitely_missing_cmd" "$WORK/run.out"
check_contains "missing script skipped" "script not found: missing_script.sh" "$WORK/run.out"
# Sequential proof: gate A runs first, waits for gate B and times out;
# gate B then finds gate A's marker and succeeds.
check_contains "gate a serialized (timed out)" "✗ Gate A Step timed out" "$WORK/run.out"
check_contains "gate b ran after gate a" "✓ Gate B Step completed successfully" "$WORK/run.out"
check_contains "summary shows elapsed time" "Elapsed:" "$WORK/run.out"
check_contains "summary formats failures as bullet points" "  - Fail Step" "$WORK/run.out"

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

echo "== parallel exit-code attribution =="
# Twins exit 10/20 at the same instant; run several rounds because the old
# wait-n-based reaper misattributed codes only when reaping raced.
for iter in 1 2 3 4 5 6; do
    run env AIDEV_TIMEOUT=30 timeout 60 bash aidev_update.sh --jobs 2 --only Twin \
        > "$WORK/twins.out" 2>&1
    a_line=$(awk '/^Twin A Step/ && NF>=4' "$WORK/twins.out")
    b_line=$(awk '/^Twin B Step/ && NF>=4' "$WORK/twins.out")
    if printf '%s' "$a_line" | grep -qE ' 10 *$' && printf '%s' "$b_line" | grep -qE ' 20 *$'; then
        pass "twin exit codes attributed correctly (round $iter)"
    else
        fail "twin exit codes attributed correctly (round $iter: A='$a_line' B='$b_line')"
    fi
done

echo "== parallel retry keeps job slots =="
# retry_slow fails instantly and its successful retry takes 12s; wait_a_bit
# finishes after 1s. Correct reaping attributes each exit code to its own
# step, so retry_slow's total must be ~12s. A reaper that double-counts the
# retried index finishes the stale entry with wait_a_bit's status after ~1s.
rm -f "$WORK/retry_slow.marker"
run env AIDEV_TIMEOUT=30 AIDEV_RETRIES=2 timeout 90 \
    bash aidev_update.sh --jobs 2 --only "Retry Slow" --only "Wait A Bit" > "$WORK/retryslots.out" 2>&1
check_eq "retry run exits 0" 0 "$?"
check_contains "retry slow succeeded" "✓ Retry Slow Step completed successfully" "$WORK/retryslots.out"
check_contains "wait a bit succeeded" "✓ Wait A Bit Step completed successfully" "$WORK/retryslots.out"
rs_secs=$(awk '/^Retry Slow Step/ && NF>=4 {print $(NF-1)}' "$WORK/retryslots.out" | tr -d 's')
if [ -n "$rs_secs" ] && [ "$rs_secs" -ge 10 ] 2>/dev/null; then
    pass "retry total spans the long second attempt (${rs_secs}s)"
else
    fail "retry total spans the long second attempt (got '${rs_secs}s')"
fi

echo "== concurrency lock =="
start_bg env AIDEV_TIMEOUT=30 bash aidev_update.sh --only "Sig Step"
first=$BG_PID
sleep 1
run bash aidev_update.sh --only "OK Step" > "$WORK/lock2.out" 2>&1
check_eq "second concurrent run exits 3" 3 "$?"
check_contains "second run names the lock" "in progress" "$WORK/lock2.out"
check_contains "second run identifies holding pid" "held by PID $first" "$WORK/lock2.out"
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

echo "== signal kills the whole step tree =="
rm -f "$WORK/tree-child.pid"
start_bg env AIDEV_TIMEOUT=120 AIDEV_KILL_AFTER=2 bash aidev_update.sh --only "Tree Step"
orch=$BG_PID
sleep 1
tree_child=$(cat "$WORK/tree-child.pid" 2>/dev/null || echo "")
kill -TERM "$orch"
for _ in $(seq 1 100); do kill -0 "$orch" 2>/dev/null || break; sleep 0.1; done
wait "$orch" 2>/dev/null
if [ -n "$tree_child" ] && kill -0 "$tree_child" 2>/dev/null; then
    fail "grandchild process cleaned up after SIGTERM"
    kill -9 "$tree_child" 2>/dev/null
else
    pass "grandchild process cleaned up after SIGTERM"
fi

echo "== parallel temp dir cleaned up on signal =="
mkdir -p "$WORK/tmp"
start_bg env TMPDIR="$WORK/tmp" AIDEV_TIMEOUT=120 AIDEV_KILL_AFTER=2 \
    bash aidev_update.sh --jobs 2 --only "Tree Step" --only "Sig Step"
orch=$BG_PID
sleep 1
kill -TERM "$orch"
for _ in $(seq 1 100); do kill -0 "$orch" 2>/dev/null || break; sleep 0.1; done
wait "$orch" 2>/dev/null
if [ -z "$(ls -A "$WORK/tmp" 2>/dev/null)" ]; then
    pass "temp dir removed after SIGTERM"
else
    fail "temp dir removed after SIGTERM (leftover: $(find "$WORK/tmp" -mindepth 1 | tr '\n' ' '))"
fi
for p in $(pgrep -f '[s]igstep\.sh'); do kill -9 "$p" 2>/dev/null; done

echo "== lock fd not inherited by steps =="
run env AIDEV_TIMEOUT=30 timeout 60 bash aidev_update.sh --only "Fd Check" > "$WORK/fdcheck.out" 2>&1
check_eq "fdcheck step succeeds" 0 "$?"
check_contains "no lock fd leak reported" "no lock fd leak" "$WORK/fdcheck.out"

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

echo "== parallel retry preserves logs =="
rm -f "$WORK/flaky.marker"
run env AIDEV_TIMEOUT=10 AIDEV_RETRIES=2 timeout 60 \
    bash aidev_update.sh --jobs 2 --only flaky.sh > "$WORK/retryparlog.out" 2>&1
check_eq "parallel retry run succeeds" 0 "$?"
check_contains "parallel retry preserves first attempt output" "flaky.sh first attempt fails" "$WORK/retryparlog.out"
check_contains "parallel retry contains retry attempt output" "flaky.sh ok on retry" "$WORK/retryparlog.out"

echo "== symlink invocation =="
LINK_DIR="$WORK/linkdir"
mkdir -p "$LINK_DIR"
ln -sf "$WORK/aidev_update.sh" "$LINK_DIR/aidev_symlink"
run bash "$LINK_DIR/aidev_symlink" --dry-run --only "OK Step" > "$WORK/symlink.out" 2>&1
check_eq "invoking via symlink succeeds" 0 "$?"
check_contains "symlink resolves script directory" "argv: bash $WORK/ok.sh" "$WORK/symlink.out"

echo "== fifo pruning =="
FIFO_TEST="$WORK/logs/.aidev-999999.fifo"
mkdir -p "$WORK/logs"
mkfifo "$FIFO_TEST" 2>/dev/null || true
touch -d '2 days ago' "$FIFO_TEST" 2>/dev/null || touch -t 202001010000 "$FIFO_TEST" 2>/dev/null || true
run bash "$WORK/aidev_update.sh" --only ok.sh > /dev/null 2>&1
if [ -e "$FIFO_TEST" ]; then
    fail "stale fifo pruned"
else
    pass "stale fifo pruned"
fi

echo "== lint (shellcheck) =="
# Optional: honours $SHELLCHECK, then PATH. Skips (does not fail) when absent
# so the suite still runs on machines without it.
SHELLCHECK="${SHELLCHECK:-$(command -v shellcheck 2>/dev/null || true)}"
if [ -n "$SHELLCHECK" ] && [ -x "$SHELLCHECK" ]; then
    if "$SHELLCHECK" -s bash "$REPO_DIR/aidev_update.sh" > "$WORK/lint.out" 2>&1; then
        pass "aidev_update.sh is shellcheck clean"
    else
        fail "aidev_update.sh is shellcheck clean"
        sed -n '1,40p' "$WORK/lint.out" | sed 's/^/      /'
    fi
    if "$SHELLCHECK" -s bash "$REPO_DIR/tests/orchestrator_test.sh" > "$WORK/lint2.out" 2>&1; then
        pass "orchestrator_test.sh is shellcheck clean"
    else
        fail "orchestrator_test.sh is shellcheck clean"
        sed -n '1,40p' "$WORK/lint2.out" | sed 's/^/      /'
    fi
else
    skip "shellcheck lint (binary not found; set \$SHELLCHECK to enable)"
fi

echo "== unknown step kind =="
run bash aidev_update.sh --list > "$WORK/kindlist.out" 2>&1
check_contains "unknown kind reported by --list" "unknown step kind: bogus" "$WORK/kindlist.out"
run bash aidev_update.sh --dry-run --only "Bogus Kind Step" > "$WORK/kinddry.out" 2>&1
check_contains "unknown kind skipped in dry-run" "unknown step kind: bogus" "$WORK/kinddry.out"
check_absent "unknown kind never resolved as a script" "would run" "$WORK/kinddry.out"

echo "== dependency gate is advisory =="
DEPBIN="$WORK/depbin"
mkdir -p "$DEPBIN"
# 'echo' is included as a real binary: the substring match on "OK Step" also
# selects the cmd-kind step, which timeout(1) has to exec from PATH. 'type -P'
# rather than 'command -v' because the latter answers with the builtin name
# for echo, which would link the name to itself.
for b in dirname date mkdir rm find timeout sleep kill flock mkfifo bash cat awk sed grep tee pgrep ps readlink basename uname hostname env echo; do
    src="$(type -P "$b" 2>/dev/null)" && [ -n "$src" ] && ln -sf "$src" "$DEPBIN/$b"
done
rm -f "$DEPBIN/npm" "$DEPBIN/curl"

timeout 60 env PATH="$DEPBIN" AIDEV_NO_LOG=1 bash "$WORK/aidev_update.sh" \
    --only "OK Step" > "$WORK/nodeps.out" 2>&1
check_eq "missing npm/curl does not block unrelated steps" 0 "$?"
check_contains "missing tools reported as a warning" "npm" "$WORK/nodeps.out"
check_contains "step still runs without npm" "OK Step completed successfully" "$WORK/nodeps.out"

timeout 60 env PATH="$DEPBIN" AIDEV_NO_LOG=1 AIDEV_REQUIRE=npm,curl \
    bash "$WORK/aidev_update.sh" --only "OK Step" > "$WORK/reqdeps.out" 2>&1
check_eq "AIDEV_REQUIRE makes a missing tool fatal (exit 4)" 4 "$?"
check_contains "required dependency named" "npm" "$WORK/reqdeps.out"

timeout 60 env PATH="$DEPBIN" AIDEV_NO_LOG=1 bash "$WORK/aidev_update.sh" \
    --require npm --only "OK Step" > "$WORK/reqflag.out" 2>&1
check_eq "--require makes a missing tool fatal (exit 4)" 4 "$?"

echo "== option parsing regressions =="
run bash aidev_update.sh --timeout > "$WORK/opt1.out" 2>&1
check_eq "--timeout without a value rejected" 2 "$?"
run bash aidev_update.sh --log-dir= > "$WORK/opt2.out" 2>&1
check_eq "--log-dir= with empty value rejected" 2 "$?"
run bash aidev_update.sh --frobnicate > "$WORK/opt3.out" 2>&1
check_eq "unknown option rejected" 2 "$?"
check_contains "unknown option names itself" "Unknown option: --frobnicate" "$WORK/opt3.out"
run bash aidev_update.sh -t=15 -k=3 -r=2 --dry-run --only "OK Step" > "$WORK/opt4.out" 2>&1
check_eq "short =value forms accepted" 0 "$?"
run bash aidev_update.sh --kill-after abc > "$WORK/opt5.out" 2>&1
check_eq "--kill-after abc rejected" 2 "$?"
run bash aidev_update.sh --jobs > "$WORK/opt6.out" 2>&1
check_eq "--jobs without a value rejected" 2 "$?"

echo "== tunable warnings printed once =="
run env AIDEV_TIMEOUT=abc AIDEV_NO_LOG=1 timeout 60 bash aidev_update.sh \
    --only "OK Step" > "$WORK/warnonce.out" 2>&1
warn_count=$(grep -c 'AIDEV_TIMEOUT must be' "$WORK/warnonce.out" || true)
check_eq "invalid AIDEV_TIMEOUT warned exactly once" 1 "$warn_count"

echo "== SIGHUP cleanup =="
rm -f "$WORK/tree-child.pid"
start_bg env AIDEV_TIMEOUT=120 AIDEV_KILL_AFTER=2 bash aidev_update.sh --only "Tree Step"
orch=$BG_PID
sleep 1
tree_child=$(cat "$WORK/tree-child.pid" 2>/dev/null || echo "")
kill -HUP "$orch"
for _ in $(seq 1 100); do kill -0 "$orch" 2>/dev/null || break; sleep 0.1; done
if kill -0 "$orch" 2>/dev/null; then
    fail "SIGHUP terminates the orchestrator"
    kill -9 "$orch" 2>/dev/null
else
    wait "$orch" 2>/dev/null
    check_eq "SIGHUP exit code is 129" 129 "$?"
fi
if [ -n "$tree_child" ] && kill -0 "$tree_child" 2>/dev/null; then
    fail "SIGHUP cleans up the step tree"
    kill -9 "$tree_child" 2>/dev/null
else
    pass "SIGHUP cleans up the step tree"
fi

echo "== log header provenance =="
run timeout 60 bash aidev_update.sh --only "OK Step" > "$WORK/prov.out" 2>&1
check_eq "provenance run exits 0" 0 "$?"
check_contains "header reports version" "Version:" "$WORK/prov.out"
check_contains "header reports the running version" "1.4.0" "$WORK/prov.out"
check_contains "header reports host" "Host:" "$WORK/prov.out"
check_contains "header reports the command line" "--only OK Step" "$WORK/prov.out"
prov_log=$(find "$WORK/logs" -maxdepth 1 -type f -name 'aidev-*.log' 2>/dev/null | sort | tail -1)
if [ -n "$prov_log" ] && grep -qF "Version:" "$prov_log"; then
    pass "provenance lands in the log file"
else
    fail "provenance lands in the log file"
fi

echo "== script hygiene =="
if grep -q '^STEP_ATTEMPT_SECONDS=0' "$REPO_DIR/aidev_update.sh"; then
    pass "STEP_ATTEMPT_SECONDS declared with the step globals"
else
    fail "STEP_ATTEMPT_SECONDS declared with the step globals"
fi
check_absent "no stale zombie claim in the wait_for_pid comment" \
    "zombies still answer" "$REPO_DIR/aidev_update.sh"

echo "== parallel wrapper killed does not hang =="
start_bg env AIDEV_NO_LOG=1 AIDEV_TIMEOUT=60 AIDEV_KILL_AFTER=2 \
    bash aidev_update.sh --jobs 2 --only "Killable Step" --only "Wait A Bit Step"
orch=$BG_PID
sleep 3
# SIGKILL the surviving wrapper subshell: it dies before recording an exit
# code, so the reaper must notice the dead pid instead of polling forever.
for c in $(pgrep -P "$orch" 2>/dev/null); do
    case "$(ps -o cmd= -p "$c" 2>/dev/null)" in
        *aidev_update.sh*) kill -9 "$c" 2>/dev/null ;;
    esac
done
hang_deadline=$((SECONDS + 30))
while kill -0 "$orch" 2>/dev/null && [ "$SECONDS" -lt "$hang_deadline" ]; do sleep 0.2; done
if kill -0 "$orch" 2>/dev/null; then
    fail "killed wrapper does not wedge the run (still running after 30s)"
    kill -9 "$orch" 2>/dev/null
    wait "$orch" 2>/dev/null
else
    wait "$orch" 2>/dev/null
    check_eq "killed wrapper makes the run fail rather than hang" 1 "$?"
    check_contains "killed step reported as a failure" \
        "Killable Step failed" "$WORK/bg.out"
fi
for p in $(pgrep -f '[k]illable\.sh'); do kill -9 "$p" 2>/dev/null; done

echo "== external steps.conf =="
CFG="$WORK/cfgdir"
mkdir -p "$CFG"
cp "$WORK/aidev_update.sh" "$CFG/aidev_update.sh"
cp "$WORK/ok.sh" "$CFG/ok.sh"
cat > "$CFG/steps.conf" <<'EOF'
# Comment lines and blank lines are ignored.

script|ok.sh|Config OK Step
cmd|echo from-config|Config Cmd Step
this-line-is-malformed
EOF
( cd "$CFG" && timeout 30 bash aidev_update.sh --list ) > "$WORK/cfglist.out" 2>&1
check_eq "steps.conf --list exits 0" 0 "$?"
check_contains "steps.conf entries are used" "Config OK Step" "$WORK/cfglist.out"
check_contains "steps.conf source is reported" "steps.conf" "$WORK/cfglist.out"
check_absent "embedded step table is replaced" "Fail Step" "$WORK/cfglist.out"
check_contains "malformed config line is reported" "malformed step" "$WORK/cfglist.out"

( cd "$CFG" && AIDEV_NO_LOG=1 timeout 30 bash aidev_update.sh --only "Config Cmd" ) \
    > "$WORK/cfgrun.out" 2>&1
check_eq "steps.conf run exits 0" 0 "$?"
check_contains "steps.conf step actually runs" "from-config" "$WORK/cfgrun.out"

cat > "$WORK/alt-steps.conf" <<'EOF'
cmd|echo from-alt-config|Alt Config Step
EOF
run env AIDEV_STEPS_FILE="$WORK/alt-steps.conf" AIDEV_NO_LOG=1 timeout 30 \
    bash aidev_update.sh > "$WORK/altcfg.out" 2>&1
check_eq "AIDEV_STEPS_FILE run exits 0" 0 "$?"
check_contains "AIDEV_STEPS_FILE steps are used" "from-alt-config" "$WORK/altcfg.out"

run env AIDEV_STEPS_FILE="$WORK/definitely-missing.conf" timeout 30 \
    bash aidev_update.sh --list > "$WORK/missingcfg.out" 2>&1
check_eq "missing AIDEV_STEPS_FILE rejected" 2 "$?"
check_contains "missing AIDEV_STEPS_FILE named" "definitely-missing.conf" "$WORK/missingcfg.out"

echo ""
echo "====================================="
echo "Tests passed: $PASS  failed: $FAIL  skipped: $SKIP"
echo "====================================="
[ "$FAIL" -eq 0 ]
