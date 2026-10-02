#!/usr/bin/env bash
#
# tests/aidev_update_test.sh — tests for the lean v2 aidev_update.sh.
#
# Each test builds a sandbox with a copy of the real script plus fake
# *_update.sh tools that record they ran via marker files. Every sandbox is
# a fresh directory (no in-run cleanup), so tests cannot leak into each other.
#
# Exit: 0 when every test passes, 1 otherwise.

set -u

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_ROOT="$(mktemp -d)"
trap 'rm -rf "$WORK_ROOT"' EXIT
SB_N=0

PASS=0 FAIL=0 SKIP=0
pass() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }
skip() { echo "  - $1 (skipped)"; SKIP=$((SKIP + 1)); }
check_eq() {
    if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (want: $3, got: $2)"; fi
}
check_file() { if [ -f "$1" ]; then pass "$2"; else fail "$2"; fi; }
check_nofile() { if [ ! -f "$1" ]; then pass "$2"; else fail "$2"; fi; }
check_grep() { if grep -q -- "$2" "$3"; then pass "$1"; else fail "$1"; fi; }
check_nogrep() { if grep -q -- "$2" "$3"; then fail "$1"; else pass "$1"; fi; }
check_out() { if grep -q -- "$2" <<<"$3"; then pass "$1"; else fail "$1"; fi; }
check_noout() { if grep -q -- "$2" <<<"$3"; then fail "$1"; else pass "$1"; fi; }

new_sandbox() {
    SB_N=$((SB_N + 1))
    WORK="$WORK_ROOT/sb$SB_N"
    mkdir -p "$WORK"
    cp "$REPO_DIR/aidev_update.sh" "$WORK/aidev_update.sh"
}

# run_main — runs the sandboxed orchestrator from its sandbox (non-tty).
# Sets OUT and RC.
run_main() {
    OUT=$(cd "$WORK" && bash aidev_update.sh 2>&1 </dev/null)
    RC=$?
}

# menu_main "keystrokes" — forces the menu and pipes the keystrokes plus a
# final newline (the enter) to it. Command substitution strips trailing
# newlines from the caller's argument, so the newline is added here.
menu_main() {
    OUT=$(cd "$WORK" && printf '%s\n' "${1:-}" | AIDEV_MENU_FORCE=1 bash aidev_update.sh 2>&1)
    RC=$?
}

# Fake tools. The ok/fail/hang variants record they ran via marker files.
mktool() { printf '#!/usr/bin/env bash\necho x >> %s.ran\n' "$1" > "$WORK/${1}_update.sh"; }
mkfail() { printf '#!/usr/bin/env bash\necho x >> %s.ran\nexit 3\n' "$1" > "$WORK/${1}_update.sh"; }
mkhang() { printf '#!/usr/bin/env bash\necho x >> %s.ran\nsleep 30\n' "$1" > "$WORK/${1}_update.sh"; }

echo "== 1. non-tty, no selection.md: everything runs, no file created =="
new_sandbox
mktool aa
mktool bb
run_main
check_eq "exit 0" "$RC" "0"
check_file "$WORK/aa.ran" "aa ran"
check_file "$WORK/bb.ran" "bb ran"
check_nofile "$WORK/selection.md" "selection.md not created"

echo "== 2. selection.md [ ] entries are skipped =="
new_sandbox
mktool aa
mktool bb
printf -- '- [ ] aa_update.sh\n- [x] bb_update.sh\n' > "$WORK/selection.md"
run_main
check_eq "exit 0" "$RC" "0"
check_nofile "$WORK/aa.ran" "aa did not run"
check_file "$WORK/bb.ran" "bb ran"

echo "== 3. menu: down + space toggles, enter saves and runs =="
new_sandbox
mktool aa
mktool bb
menu_main "$(printf '\033[B \n')"
check_eq "exit 0" "$RC" "0"
check_file "$WORK/aa.ran" "aa ran (still on)"
check_nofile "$WORK/bb.ran" "bb did not run (toggled off)"
check_grep "selection.md marks aa on" "- \[x\] aa_update.sh" "$WORK/selection.md"
check_grep "selection.md marks bb off" "- \[ \] bb_update.sh" "$WORK/selection.md"
run_main                      # second, non-tty run honors the saved file
check_eq "second run exit 0" "$RC" "0"
check_eq "aa ran twice" "$(wc -l < "$WORK/aa.ran")" "2"
check_nofile "$WORK/bb.ran" "bb still off on second run"

echo "== 4. menu: q and Esc cancel without running or saving =="
new_sandbox
mktool aa
printf -- '- [ ] aa_update.sh\n' > "$WORK/selection.md"
cp "$WORK/selection.md" "$WORK/selection.orig"
menu_main "q"
check_eq "q exit 0" "$RC" "0"
check_nofile "$WORK/aa.ran" "q: nothing ran"
check_eq "q: selection.md unchanged" \
    "$(cmp -s "$WORK/selection.md" "$WORK/selection.orig" && echo same)" "same"
menu_main "$(printf '\033')"
check_eq "Esc exit 0" "$RC" "0"
check_nofile "$WORK/aa.ran" "Esc: nothing ran"
check_eq "Esc: selection.md unchanged" \
    "$(cmp -s "$WORK/selection.md" "$WORK/selection.orig" && echo same)" "same"

echo "== 5. a failing tool does not stop the rest, exit 1 =="
new_sandbox
mktool aa
mkfail cc
run_main
check_eq "exit 1" "$RC" "1"
check_file "$WORK/aa.ran" "aa still ran"
check_file "$WORK/cc.ran" "cc ran and failed"
check_out "summary names the failure" "failed: cc" "$OUT"
check_out "aa reported ok" "✓ aa" "$OUT"

echo "== 6. a hung tool is stopped by the step timeout =="
new_sandbox
mktool aa
mkhang dd
OUT=$(cd "$WORK" && AIDEV_STEP_TIMEOUT=2 bash aidev_update.sh 2>&1 </dev/null)
RC=$?
check_eq "exit 1" "$RC" "1"
check_file "$WORK/aa.ran" "aa ran after the hang"
check_out "dd reported failed" "✗ dd" "$OUT"

echo "== 7. selection file self-heals: new tools default on, stale lines drop =="
new_sandbox
mktool aa
menu_main $'\n'                      # immediate enter: save defaults, run aa
check_grep "file written for aa" "aa_update.sh" "$WORK/selection.md"
mktool ee                            # tool added after the save
rm -f "$WORK/aa.ran"
printf -- '- [x] zz_update.sh\n' >> "$WORK/selection.md"   # stale entry
run_main
check_file "$WORK/aa.ran" "saved aa still on"
check_file "$WORK/ee.ran" "new ee defaulted on"
menu_main $'\n'                      # save again: zz must disappear, ee recorded
check_grep "ee recorded" "- \[x\] ee_update.sh" "$WORK/selection.md"
check_nogrep "stale zz dropped" "zz" "$WORK/selection.md"

echo "== 8. self-discovery guard =="
new_sandbox
mktool aa
# a decoy legacy script that must NOT be picked up by the *_update.sh glob
printf '#!/usr/bin/env bash\necho x >> v1.ran\n' > "$WORK/aidev_update_v1.sh"
OUT=$(cd "$WORK" && timeout 60 bash aidev_update.sh 2>&1 </dev/null)
RC=$?
check_eq "exit 0 (no recursion)" "$RC" "0"
check_file "$WORK/aa.ran" "aa ran"
check_nofile "$WORK/v1.ran" "aidev_update_v1.sh not discovered"
check_noout "v1 never mentioned" "v1" "$OUT"

echo "== 9. empty selection =="
new_sandbox
mktool aa
printf -- '- [ ] aa_update.sh\n' > "$WORK/selection.md"
run_main
check_eq "exit 0" "$RC" "0"
check_nofile "$WORK/aa.ran" "nothing ran"
check_out "reports nothing selected" "Nothing selected" "$OUT"

echo "== 10. shellcheck =="
SHELLCHECK="${SHELLCHECK:-$(command -v shellcheck 2>/dev/null || true)}"
if [ -n "$SHELLCHECK" ] && [ -x "$SHELLCHECK" ]; then
    if "$SHELLCHECK" -s bash "$REPO_DIR/aidev_update.sh"; then
        pass "aidev_update.sh is shellcheck clean"
    else
        fail "aidev_update.sh is shellcheck clean"
    fi
else
    skip "shellcheck not available"
fi

echo ""
echo "====================================="
echo "Tests passed: $PASS  failed: $FAIL  skipped: $SKIP"
echo "====================================="
[ "$FAIL" -eq 0 ]
