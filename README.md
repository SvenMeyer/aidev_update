# AI Dev Tools Update Script

A small orchestrator that keeps a set of AI-powered development CLI tools up
to date through a single command.

> **Note:** This repository has only been tested on "plain" Linux (Manjaro Linux).

## Overview

`aidev_update.sh` runs a configurable list of updater steps — sequentially by
default, or up to N at a time with `--jobs N`. Each step is either a sibling
`*_update.sh` script or a bare command such as `claude update`. A failure in
one step does not stop the rest of the run; every step is attempted, then a
summary is printed and the exit code reflects whether anything failed.

## Prerequisites

- **bash** >= 4.4 (the orchestration script and the individual updaters)
- **npm** (used by several npm-based tool updaters)
- **curl** (used by several download-based updaters)
- **pipx** and **python3** (for the Python-based tools: mini-swe-agent, headroom)
- **coreutils** (`timeout`, `mkfifo`, `tee`) for per-step timeouts and logging
- **flock** (optional) to prevent two runs from racing the package managers

`aidev_update.sh` checks for **npm** and **curl** up front and exits `1` if either
is missing. Remaining tools are checked by the individual update scripts, and
per-step prerequisites (a missing command or missing script) are reported in a
preflight pass and skipped rather than failing the run. Logging is
self-disabling: if `mkfifo` or `tee` is unavailable, the run continues without a
log file instead of hanging.

## Usage

```bash
./aidev_update.sh                     # run every enabled step
./aidev_update.sh --only grok         # run only matching step(s)
./aidev_update.sh grok                # positional names work like --only
./aidev_update.sh --skip gastown      # run everything except matching step(s)
./aidev_update.sh --jobs 4            # run up to 4 steps at the same time
./aidev_update.sh --timeout 120       # 2 minute cap per step
./aidev_update.sh --retries 2         # one extra try on failure
./aidev_update.sh --dry-run           # show what would run, change nothing
./aidev_update.sh --list              # list steps and their availability
./aidev_update.sh --version           # print version information
./aidev_update.sh --help              # full usage
```

Matching is a case-insensitive substring test against a step's target and
description, so `--only gastown` selects both the Gastown and Gastown GUI steps,
and a broad pattern such as `--only open` matches several steps at once.

With `--jobs N` up to N steps run concurrently; each step's output is buffered
and printed when the step finishes, so parallel logs stay readable and the
summary keeps the configured step order. On retries, output from previous
attempts is preserved rather than overwritten.

Only one run may be active at a time. A second run exits `1` with the holding
PID and lock path if `flock` is available; without `flock` the guard is skipped.

### Options and Environment Variables

Every setting can be specified via a command-line flag or an environment variable:

| CLI Option             | Environment Variable      | Default             | Purpose                                         |
| ---------------------- | ------------------------- | ------------------- | ----------------------------------------------- |
| `-t, --timeout SECS`   | `AIDEV_TIMEOUT`           | `600`               | Per-step timeout in seconds (`0` disables it)   |
| `-k, --kill-after SECS`| `AIDEV_KILL_AFTER`        | `10`                | Grace period after SIGTERM before SIGKILL       |
| `-r, --retries N`      | `AIDEV_RETRIES`           | `1`                 | Attempts per failed step (no retry by default)  |
| `--log-dir DIR`        | `AIDEV_LOG_DIR`           | `<script dir>/logs` | Directory for run logs                          |
| (env only)             | `AIDEV_LOG_RETENTION_DAYS`| `30`                | Delete run logs older than this (`0` = keep all)|
| `--no-log`             | `AIDEV_NO_LOG`            | unset               | Set to `1` to disable logging                   |

Each run is logged to `logs/aidev-<timestamp>-<pid>.log` (git-ignored). A FIFO is
used for logging so terminal and log ordering stay correct even when output is
piped elsewhere, and terminal descriptors are cleanly restored on shutdown. Old
logs and stale FIFOs are pruned after each run according to
`AIDEV_LOG_RETENTION_DAYS`.

Steps run with stdin redirected from `/dev/null` so unattended or background jobs
never freeze on prompts or `SIGTTIN`. Steps are run under `timeout --kill-after`
so a step that ignores SIGTERM is eventually killed instead of blocking the run.
A step that exits `124`/`137` on its own is reported as a failure, not as a timeout.
On `SIGINT`/`SIGTERM` the running steps — and their whole descendant trees, e.g. `npm`
children — receive termination signals simultaneously and the script exits
`130`/`143` respectively. The lock descriptor is never inherited by spawned steps,
so daemons a step leaves behind cannot hold the concurrency lock after the run ends.

## Tools Managed

Enabled steps, in run order:

| Step                    | Kind        | Notes                              |
| ----------------------- | ----------- | ---------------------------------- |
| OpenSpec Update         | script      | `openspec_update.sh`               |
| mini-swe-agent Update   | script      | pipx-based                         |
| Claude Code CLI Update  | command     | `claude update`                    |
| Grok CLI Update         | script      | `grok_update.sh`                   |
| DROID CLI Update        | command     | `droid update`                     |
| OpenAI Codex Update     | script      | `codex_update.sh`                  |
| OpenCode CLI Update     | script      | `opencode_update.sh`               |
| Entire Update           | script      | `entire_update.sh`                 |
| Headroom Update         | script      | `headroom_update.sh`               |
| Kilo Update             | script      | `kilo_update.sh`                   |
| Beads Update            | script      | `beads_update.sh`                  |
| Gastown Update          | script      | `gastown_update.sh`                |
| Gastown GUI Update      | script      | `gastown_gui_update.sh`            |
| Repowise Update         | script      | `repowise_update.sh`               |

Additional updater scripts exist in the repository but are disabled by default
(Claude updater script, Copilot, CCR, Gemini, Qwen, Amp, LLxprt, JustCode,
Codebuff, Taskmaster, CLIProxyAPI, Ollama, Pi Coding Agent). Run
`./aidev_update.sh --list` to see them, and see "Adding or changing steps" below
to re-enable one.

## Adding or changing steps

Steps live in two arrays at the top of `aidev_update.sh`:

```bash
STEPS=(
    "script|openspec_update.sh|OpenSpec Update"
    "cmd|claude update|Claude Code CLI Update"
    ...
)
```

Each entry is `kind|target|description`:

- `kind=script` — `target` is an updater script (relative to script dir or absolute), run with `bash`.
- `kind=cmd` — `target` is a command line, split on whitespace and run directly.
- `kind=sh` — `target` is a shell expression evaluated with `bash -c`, supporting quotes, pipes, and flags.

To disable a step, move its line into `DISABLED_STEPS`; to enable, move it back.

## Features

- **Declarative step list** — add, remove, reorder, or toggle a step in one line
- **Preflight checks** — missing commands or scripts are reported before the run
- **Subset selection** — `--only`, `--skip`, and positional name filters
- **Dry run** — `--dry-run` resolves every selected step, reports it and shows
  the exact argv that would run
- **Parallel runs** — `--jobs N` runs steps concurrently with buffered,
  non-interleaved output; each step's exit code is recorded by its own wrapper,
  so statuses are attributed exactly even when steps finish simultaneously
- **Retries** — `AIDEV_RETRIES` retries a step that exits non-zero (a retry
  always re-runs its own step, in both sequential and parallel modes)
- **Error isolation** — one failed update does not stop the others
- **Per-step timeout** — `timeout --kill-after` stops even a SIGTERM-ignoring
  updater from blocking the run
- **Signal handling** — `SIGINT`/`SIGTERM` terminate the running steps and
  their process trees and exit `130`/`143`; parallel-mode temp dirs are
  removed even on signal-interrupted runs
- **Concurrency guard** — `flock` prevents two runs from clashing; a read-only
  install directory only disables the guard instead of aborting
- **Timing and summary** — per-step status, duration and exit-code table at the
  end
- **Run logging** — full output tee'd to a timestamped log file, with retention
  pruning and a safe fallback when `tee` is unavailable
- **Honest exit code** — non-zero when any step failed

## Testing

`tests/orchestrator_test.sh` builds a throwaway copy of the orchestrator with
stub steps and checks selection, dry-run, timeouts, exit-code classification,
retries, parallel runs (including exit-code attribution when steps finish
simultaneously), skip handling, logging, the concurrency lock (including that
steps never inherit the lock fd), signal handling (including process-tree and
temp-dir cleanup) and the no-`tee`/no-`timeout` fallbacks:

```bash
./tests/orchestrator_test.sh
```

## Exit Codes

- `0` — every attempted step succeeded (skipped steps are allowed)
- `1` — missing core dependencies, a concurrent run is active, or one or more steps failed/timed out
- `2` — invalid command-line usage, or no step matched the `--only`/`--skip` filters
