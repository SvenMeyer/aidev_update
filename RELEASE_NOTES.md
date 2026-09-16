# Release Notes

## 2026-09-16 (v1.2.1)

### Orchestrator correctness fixes (`aidev_update.sh`)

Contributed by **qwen/qwen3.8-max-0902**.

**Fixes**

- **Parallel mode attributed exit codes to the wrong steps.** `wait -n` returns
  the status of *some* finished job, and the follow-up `kill -0` sweep picked
  the first dead pid in flight order — not necessarily the same process. When
  two steps finished simultaneously, their exit codes (and thus pass/fail,
  retries and the summary) could be swapped. Each parallel step now runs inside
  a wrapper subshell that records its exact exit code in a per-step rc file,
  and reaping polls those files, so attribution is exact by construction. As a
  side effect, the log `tee` job can no longer be mistaken for a finished step.
- **Parallel retries re-ran the wrong command.** A retry relaunched whatever
  `STEP_CMD` held at retry time — the *last resolved* step, not the failed one
  (a latent bug since v1.2.0, previously masked because retries were only
  exercised on single-step selections). Steps are now resolved per launch, so
  a retry always re-runs its own step; if it vanished meanwhile, the retry is
  reported as un-runnable instead of silently running something else.
- **A retried step double-counted its job slot** (its index stayed in the
  in-flight list twice), silently reducing parallelism under `--jobs`. Finished
  indices are now removed before the retry relaunches them.
- **The concurrency lock fd leaked into every step.** Children inherited fd 8,
  so a daemon left behind by a step (e.g. Gastown/Headroom services) could hold
  the flock after the run ended and wedge all future runs with "another run is
  in progress". Steps are now spawned with `8>&-`.
- **Signals only killed direct children**, orphaning grandchildren such as the
  `npm` processes an updater spawns, and (in parallel mode) the wrapper's inner
  process. The handler now kills the whole descendant tree, deepest first,
  escalating to `SIGKILL` on the same schedule as before.
- **The parallel-mode temp dir leaked on signal-interrupted runs**; it is now
  removed via the `EXIT` trap.
- Misconfiguration warnings (`AIDEV_TIMEOUT` & co.) are printed once logging is
  engaged, so they are captured in the run log instead of only on the terminal.

**Improvements**

- A `--only`/`--skip` filter that matches nothing now lists the available
  steps before exiting `2`.
- `aidev_update.sh` is shellcheck-clean at `-S style`; the parallel executor no
  longer uses `wait -n` at all.
- Test suite grew from 53 to 68 checks, including regressions for every fix
  above (simultaneous-finish attribution, retry duration/attribution, lock-fd
  inheritance, process-tree cleanup, temp-dir cleanup).

## 2026-09-16 (v1.2.0)

### Orchestrator review fixes & parallel execution (`aidev_update.sh`)

Release prepared by **z-ai/glm-5.3**.

**Fixes**

- A step that exits `124`/`137` on its own is no longer misreported as a
  timeout. Timeout classification now requires the `timeout(1)` wrapper, a
  positive `AIDEV_TIMEOUT`, and that at least the configured limit actually
  elapsed; timeout messages also report the real elapsed time instead of the
  configured limit.
- Signal exit codes now follow the usual convention: `130` for `SIGINT`,
  `143` for `SIGTERM`.
- A signal arriving in the microseconds between launching a step and recording
  its pid no longer orphans the step: the handler now sweeps any remaining
  direct children (the log tee excepted).
- An unopenable lock file (e.g. a read-only install directory) now warns and
  continues without the concurrency guard instead of killing the script with
  a cryptic redirection error.
- Fractional `sleep 0.1` is now detected once at startup; systems whose
  `sleep(1)` rejects fractional intervals fall back to whole-second polling
  instead of mis-timing the SIGKILL grace period.
- A bash < 4.4 environment now fails fast with a clear message instead of a
  confusing syntax error.

**Additions**

- `--jobs N` runs steps concurrently (default remains strictly sequential).
  Each step's output is buffered and printed when the step finishes, so logs
  stay readable and the summary keeps the configured order.
- `AIDEV_RETRIES` (default `1`) retries a step that exits non-zero; retries
  work in both sequential and parallel modes.
- Exit codes are shown in the per-step status line and the summary table.
- `--list` now shows each step's current availability (`runnable` or the skip
  reason).
- `--dry-run` prints the exact argv that would run for each step.
- Usage notes now document that pattern matching is a case-insensitive
  substring test against both target and description, that `cmd` steps cannot
  contain quoting/spaces, and that `AIDEV_TIMEOUT=0` disables the timeout.
- Missing `find` (used for log pruning) now produces a warning instead of
  silently doing nothing.

**Testing**

- `tests/orchestrator_test.sh` grew from 25 to 53 tests, adding coverage for
  exit-code classification (own-124 vs. real timeouts, with and without
  `timeout(1)`), retries, parallel runs with a rendezvous test that deadlocks
  if steps are not really concurrent, SIGINT/SIGTERM exit codes, the read-only
  lock directory and the no-`timeout` fallback.

## 2026-09-16 (v1.1.0)

### Orchestrator hardening (`aidev_update.sh`)

Release prepared by **deepseek-v4.1-flash**.

**Fixes**

- Skipped steps no longer report the previous step's duration; `STEP_SECONDS` is
  reset for every step.
- Logging can no longer hang the run: `mkfifo`/`tee` availability is checked
  before engaging the log FIFO, and cleanup bounds its wait for `tee` so an
  orphaned child holding the pipe cannot stall the exit.
- Per-step timeouts now use `timeout --kill-after`, so an updater that ignores
  SIGTERM is killed instead of blocking the run.

**Additions**

- `--dry-run` lists the steps that would run and which would be skipped.
- `flock`-based concurrency guard prevents two runs from racing package managers.
- `SIGINT`/`SIGTERM` terminate the running step and exit `130`.
- Log retention via `AIDEV_LOG_RETENTION_DAYS` (default 30 days).
- `AIDEV_KILL_AFTER` env var for the SIGTERM grace period.
- `tests/orchestrator_test.sh`: 25 self-contained tests covering selection,
  dry-run, timeouts, skips, logging, the lock, signal handling and the no-`tee`
  fallback.

**Changed**

- No-match `--only`/`--skip` filters now exit `2` (usage error) instead of `1`.
- Shared `resolve_step` helper removes duplicated availability checks between
  preflight, dry-run and execution.

## 2026-01-12

### Ollama Update Script Fix

**Problem**: The Ollama update script failed with a 404 error when trying to download pre-release versions (e.g., v0.14.0-rc2).

**Root Cause**: Ollama changed their Linux binary bundle format for pre-release versions:
- Stable releases (v0.13.5): Use `.tgz` (gzip) format
- Pre-releases (v0.14.0-rc2+): Use `.tar.zst` (Zstandard) format

The script was hardcoded to download `.tgz` files only.

**Fix**: Updated `ollama_update.sh` to:
- Auto-detect available bundle format by checking URL availability with redirect following
- Download the correct format (`.tgz` or `.tar.zst`)
- Install `zstd` if needed for decompression (supports apt, pacman, dnf)
- Use appropriate extraction command based on format
- Clean up cached files of both formats
