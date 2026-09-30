#!/bin/bash
# Exercise the updater with isolated CLI/package/daemon state; no real installs or restarts.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UPDATE_SCRIPT="${CODEX_UPDATE_SCRIPT:-$REPO_DIR/codex_update.sh}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir "$WORK/bin"

cat > "$WORK/bin/npm" <<'EOF'
#!/bin/bash
set -euo pipefail
printf 'npm %s\n' "$*" >> "$CODEX_TEST_STATE/calls"
case "$1" in
    view)
        [[ "${CODEX_TEST_RESOLVE_FAIL:-0}" != 1 ]] || exit 1
        cat "$CODEX_TEST_STATE/target"
        ;;
    install)
        [[ "${CODEX_TEST_INSTALL_FAIL:-0}" != 1 ]] || exit 1
        [[ "$2" == -g && "$3" == "@openai/codex@$(cat "$CODEX_TEST_STATE/target")" ]]
        cat "$CODEX_TEST_STATE/target" > "$CODEX_TEST_STATE/cli"
        ;;
    *) exit 2 ;;
esac
EOF

cat > "$WORK/bin/codex" <<'EOF'
#!/bin/bash
set -euo pipefail
printf 'codex %s\n' "$*" >> "$CODEX_TEST_STATE/calls"
case "$*" in
    --version) printf 'codex-cli %s\n' "$(cat "$CODEX_TEST_STATE/cli")" ;;
    'app-server daemon update --help')
        [[ "${CODEX_TEST_UNSUPPORTED:-0}" != 1 ]] || exit 2
        echo 'Options: --from-cli --yes'
        ;;
    'app-server daemon version')
        [[ "${CODEX_TEST_STATUS_FAIL:-0}" != 1 ]] || exit 1
        printf '{"cliVersion":"%s","managedCodexVersion":"%s","appServerVersion":"%s"}\n' \
            "$(cat "$CODEX_TEST_STATE/cli")" "$(cat "$CODEX_TEST_STATE/managed")" "$(cat "$CODEX_TEST_STATE/server")"
        ;;
    'app-server daemon update --from-cli --yes')
        [[ "${CODEX_TEST_DAEMON_FAIL:-0}" != 1 ]] || exit 1
        cat "$CODEX_TEST_STATE/cli" > "$CODEX_TEST_STATE/managed"
        cat "$CODEX_TEST_STATE/cli" > "$CODEX_TEST_STATE/server"
        ;;
    *) echo "Unexpected codex invocation: $*" >&2; exit 2 ;;
esac
EOF
chmod +x "$WORK/bin/npm" "$WORK/bin/codex"
export PATH="$WORK/bin:$PATH" CODEX_TEST_STATE="$WORK"

reset_state() {
    printf '%s\n' '0.161.0-alpha.4' > "$WORK/target"
    printf '%s\n' '0.160.0' > "$WORK/cli"
    printf '%s\n' '0.159.0' > "$WORK/managed"
    printf '%s\n' '0.159.0' > "$WORK/server"
    : > "$WORK/calls"
    unset CODEX_TEST_RESOLVE_FAIL CODEX_TEST_INSTALL_FAIL CODEX_TEST_UNSUPPORTED CODEX_TEST_STATUS_FAIL CODEX_TEST_DAEMON_FAIL
}

run_update() {
    RESULT=0
    bash "$UPDATE_SCRIPT" "$@" > "$WORK/output" 2>&1 || RESULT=$?
}

assert_eq() {
    if [[ "$1" != "$2" ]]; then
        echo "FAIL: $3 (expected '$1', got '$2')"
        cat "$WORK/output" "$WORK/calls"
        exit 1
    fi
}

assert_synced() {
    assert_eq 0 "$RESULT" "$1 succeeds"
    assert_eq "$(cat "$WORK/target")" "$(cat "$WORK/managed")" "$1 pins the managed package"
    assert_eq "$(cat "$WORK/target")" "$(cat "$WORK/server")" "$1 updates the running daemon"
}

reset_state
run_update
assert_synced 'CLI upgrade'
assert_eq 'npm view @openai/codex@alpha version' "$(head -1 "$WORK/calls")" 'alpha is the default'
echo 'PASS: CLI upgrade also updates the daemon from the alpha CLI'

reset_state
cp "$WORK/target" "$WORK/cli"
run_update
assert_synced 'Already-current CLI with stale daemon'
! grep -q '^npm install' "$WORK/calls"
echo 'PASS: already-current CLI still repairs a stale daemon without reinstalling npm'

reset_state
cp "$WORK/target" "$WORK/cli"
cp "$WORK/target" "$WORK/managed"
run_update
assert_synced 'Current managed package with stale running daemon'
echo 'PASS: matching managed package does not hide a stale running daemon'

reset_state
cp "$WORK/target" "$WORK/cli"
cp "$WORK/target" "$WORK/managed"
cp "$WORK/target" "$WORK/server"
run_update
assert_synced 'Already-current daemon'
! grep -q '^codex app-server daemon update --from-cli' "$WORK/calls"
echo 'PASS: already-current daemon is not restarted'

for tag in latest beta; do
    reset_state
    printf '%s\n' '0.161.0' > "$WORK/target"
    run_update "$tag"
    assert_synced "$tag update"
    assert_eq "npm view @openai/codex@$tag version" "$(head -1 "$WORK/calls")" "$tag selection"
done
echo 'PASS: explicit npm tags are preserved'

reset_state
export CODEX_TEST_STATUS_FAIL=1
run_update
assert_synced 'Unavailable daemon status'
echo 'PASS: unavailable daemon status still attempts the managed update'

reset_state
export CODEX_TEST_UNSUPPORTED=1
run_update
assert_eq 0 "$RESULT" 'Older CLI still updates successfully'
grep -q 'skipping daemon update' "$WORK/output"
! grep -q '^codex app-server daemon update --from-cli' "$WORK/calls"
echo 'PASS: older CLI reports that daemon updates are unsupported'

reset_state
export CODEX_TEST_DAEMON_FAIL=1
run_update
assert_eq 1 "$RESULT" 'Daemon update failure propagates'
grep -q 'daemon update failed' "$WORK/output"
! grep -q '✓ Done!' "$WORK/output"
echo 'PASS: daemon failure is not reported as a successful update'

for failure in CODEX_TEST_RESOLVE_FAIL CODEX_TEST_INSTALL_FAIL; do
    reset_state
    export "$failure=1"
    run_update
    assert_eq 1 "$RESULT" "$failure propagates"
    ! grep -q '^codex app-server daemon' "$WORK/calls"
done
echo 'PASS: failed version resolution or npm install leaves the daemon untouched'
