# AI Dev Tools Update Script

A small orchestrator that keeps a set of AI-powered development CLI tools up
to date through a single command.

> **Note:** This repository has only been tested on "plain" Linux (Manjaro Linux).

## Overview

`aidev_update.sh` runs a configurable list of updater steps in sequence. Each
step is either a sibling `*_update.sh` script or a bare command such as
`claude update`. A failure in one step does not stop the rest of the run; every
step is attempted, then a summary is printed and the exit code reflects whether
anything failed.

## Prerequisites

- **bash** (the orchestration script and the individual updaters)
- **npm** (used by several npm-based tool updaters)
- **curl** (used by several download-based updaters)
- **pipx** and **python3** (for the Python-based tools: mini-swe-agent, headroom)
- **coreutils** (`timeout`, `mkfifo`, `tee`) for per-step timeouts and logging

`aidev_update.sh` checks for **npm** and **curl** up front and exits `1` if either
is missing. Remaining tools are checked by the individual update scripts, and
per-step prerequisites (a missing command or missing script) are reported in a
preflight pass and skipped rather than failing the run.

## Usage

```bash
./aidev_update.sh                     # run every enabled step
./aidev_update.sh --only grok         # run only matching step(s)
./aidev_update.sh grok                # positional names work like --only
./aidev_update.sh --skip gastown      # run everything except matching step(s)
./aidev_update.sh --list              # list enabled and disabled steps
./aidev_update.sh --help              # full usage
```

Matching is a case-insensitive substring test against a step's target and
description, so `--only gastown` selects both the Gastown and Gastown GUI steps.

### Environment variables

| Variable         | Default                  | Purpose                                  |
| ---------------- | ------------------------ | ---------------------------------------- |
| `AIDEV_TIMEOUT`  | `600`                    | Per-step timeout in seconds              |
| `AIDEV_LOG_DIR`  | `<script dir>/logs`      | Directory for run logs                   |
| `AIDEV_NO_LOG`   | unset                    | Set to `1` to disable logging            |

Each run is logged to `logs/aidev-<timestamp>-<pid>.log` (git-ignored). A FIFO is
used for logging so terminal and log ordering stay correct even when output is
piped elsewhere.

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
Codebuff, Taskmaster, CLIProxyAPI, Ollama). Run `./aidev_update.sh --list` to see
them, and see "Adding or changing steps" below to re-enable one.

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

- `kind=script` — `target` is a sibling updater script, run with `bash`.
- `kind=cmd` — `target` is a command line, run directly.

To disable a step, move its line into `DISABLED_STEPS`; to enable, move it back.

## Features

- **Declarative step list** — add, remove, reorder, or toggle a step in one line
- **Preflight checks** — missing commands or scripts are reported before the run
- **Subset selection** — `--only`, `--skip`, and positional name filters
- **Error isolation** — one failed update does not stop the others
- **Per-step timeout** — a hung updater cannot block the whole run
- **Timing and summary** — per-step status and duration table at the end
- **Run logging** — full output tee'd to a timestamped log file
- **Honest exit code** — non-zero when any step failed

## Exit Codes

- `0` — every attempted step succeeded (skipped steps are allowed)
- `1` — missing core dependencies, no step matched the filters, or one or more steps failed/timed out
- `2` — invalid command-line usage
