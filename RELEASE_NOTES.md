# Release Notes

## 2026-09-16

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
