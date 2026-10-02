# specs_v2.md — the implemented v2.0.0 spec (2026-10-02)

The plan below was approved and implemented as written. It documents why the
v2 orchestrator looks the way it does and what changed relative to v1.

---

# Lean rewrite: `aidev_update.sh` v2.0.0

## Summary

Keep the current orchestrator runnable under a legacy name, and add **one small main script written from scratch** whose only jobs are:

1. Discover every `*_update.sh` package script next to it (one script per tool — the directory *is* the tool list), excluding itself.
2. Show a checkbox menu (arrow keys up/down, `[space]` toggle, `[enter]` run, `q`/`Esc` cancel) before an interactive run; persist the choice in `selection.md` (markdown checkboxes, one line per tool).
3. Run the selected scripts **one after the other**, print a per-tool ✓/✗ and a one-line summary, exit non-zero if any failed.

No other features in the new script: no parallelism, no retries, no flags, no logging framework, no lock file, no step-table DSL. Target size ≈ 150–200 lines, verified by a small test suite (~200 lines).

User decisions:
- (2026-10-02 questionnaire) Rewrite from scratch; each package gets its own isolated update script; main script only calls them and menus. Menu inlined (no separate selector). Persistence: one line per package with on/off status — **markdown checkbox format** chosen (human-readable, human-editable, trivial to parse in bash; avoids JSON quoting in pure bash). Menu input: cursor + `[space]` + `[enter]` only — no numbers, no ranges.
- (2026-10-02 plan review) **Do not delete the old system.** Rename the old `aidev_update.sh` out of the way and keep every file it needs to run; copy this spec into `specs_v2.md` in the repo; implement as planned; **commit and push when tested**.

Naming decision (flagged for review, trivially changeable): the old orchestrator (VERSION 1.5.0) becomes `aidev_update_v1.sh`, matching the repo's own version numbering; the new lean script takes the `aidev_update.sh` name and the v2.0.0 label, documented in `specs_v2.md`. If "rename old update file to v2" was meant literally as `aidev_update_v2.sh`, it is a one-line rename at review time.

## Evidence that the old features were dead weight

- Orchestrator size history: ~150 lines (stable for 1+ year) → 395 (Sep 14) → 1,174 (Sep 16, five commits) → 1,285 (Oct 2). Plus a 517-line selector added Oct 2.
- Run logs (`logs/`, 19 files since Sep 14): **every** invocation is bare `aidev_update.sh`, except one `--only repowise`. `--jobs`, `--retries`, `--require`, `--kill-after` were never used.
- No cron/systemd timer references the script. Single interactive user.
- The old suite needs a pty driver (`drive_menu`), signal-tree test steps, simultaneous-exit twins, and gate steps to test the parallel/retry machinery — all testing unused code.

## File disposition (revised: preserve, don't delete)

| File | Now | Disposition |
|---|---|---|
| `aidev_update.sh` (v1.5.0) | 1,285-line orchestrator | **Renamed to `aidev_update_v1.sh`** (git mv), otherwise untouched — stays runnable |
| `aidev_select.sh` | 517-line selector used by the old orchestrator | **Kept as-is** (old script calls `$SCRIPT_DIR/aidev_select.sh`; still present, still works) |
| `steps.conf` | old system's local selection state (git-ignored) | **Kept** — the old script's state file; new script ignores it |
| `tests/orchestrator_test.sh` | 1,028-line suite for the old orchestrator | **Kept working**: patch the single reference `cp "$REPO_DIR/aidev_update.sh" …` (line 61) to the new `_v1` name; nothing else changes |
| `aidev_update.sh` (new, v2.0.0) | — | **Written from scratch**, takes over the canonical name |
| `tests/aidev_update_test.sh` | — | **New** ~200-line suite for the new script |
| `tests/codex_update_test.sh` | tests `codex_update.sh` only | **Kept unchanged** |
| `selection.md` | — | **New** per-machine state of the new script (git-ignored) |
| `specs_v2.md` | — | **New** — full copy of this spec, committed to the repo |
| `README.md` / `RELEASE_NOTES.md` | document the old flags | README rewritten short (one paragraph points to `aidev_update_v1.sh` as the legacy alternative); RELEASE_NOTES gets a v2.0.0 entry |
| `.gitignore` | ignores `steps.conf`, `logs/`, lock | **Add** `selection.md`; **keep** `steps.conf` and `.aidev_update.lock` entries (still used by the legacy script) |
| 27 `*_update.sh` package scripts | e.g. `grok_update.sh`, `codex_update.sh` | **Kept** — they *are* the design |

Coexistence notes (verified): `aidev_update_v1.sh` does **not** match the new `*_update.sh` discovery glob (it ends `_v1.sh`), so the new script will never pick it up. The two systems share only the directory: legacy uses `steps.conf` + `aidev_select.sh` + lock + logs; the new one uses only `selection.md`.

Current `cmd|`-style steps have no script file yet and need 2-line wrappers (below). No `sh|` steps exist (verified). Tools currently *enabled* (from `steps.conf`, used to seed the migration): claude, grok, codex, entire, headroom, repowise, graphify, pi.

## Target design

### Main script `aidev_update.sh` (structure)

```bash
#!/usr/bin/env bash
# aidev_update.sh (v2) — pick tools, run their *_update.sh one after the other.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$(basename "${BASH_SOURCE[0]}")"          # "aidev_update.sh" matches *_update.sh!
SELECTION_FILE="$SCRIPT_DIR/selection.md"
STEP_TIMEOUT="${AIDEV_STEP_TIMEOUT:-600}"       # fixed per-step cap; env override is a test knob

# --- 1. Discover tools -----------------------------------------------------
# The directory is the tool list: every *_update.sh, sorted, EXCEPT the
# orchestrator itself (its own name matches the glob — this guard is essential).
mapfile -t ALL_TOOLS < <(cd "$SCRIPT_DIR" && ls -1 *_update.sh 2>/dev/null \
                         | sort | grep -vxF "$SELF")

# --- 2. Load selection -----------------------------------------------------
# selection.md: "- [x] grok_update.sh" = on, "- [ ] name" = off.
# A tool not in the file defaults to ON (new package scripts auto-join).
# Stale entries (deleted scripts) are ignored; the menu rewrites the file on save.

# --- 3. Menu (interactive only) --------------------------------------------
# Shown when stdin AND stdout are ttys, or AIDEV_MENU_FORCE=1 (test hook).
#   ↑/↓ move cursor   [space] toggle   [enter] save+run   q/Esc cancel
# On [enter]: write selection.md (one line per discovered tool — self-healing).

# --- 4. Run ----------------------------------------------------------------
# For each selected tool, in listed order:
#   header line, then: timeout --kill-after=10 "$STEP_TIMEOUT" bash "$tool"
#   (plain "bash $tool" if timeout(1) is unavailable)
# Track ✓/✗ per tool; a failing tool does not stop the rest.

# --- 5. Summary ------------------------------------------------------------
# "N/M tools updated" + names of failures; exit 1 if any failed, else 0.
```

### Menu function spec

- One screen: title line (`aidev update — space toggles, enter runs, q quits`), one row per tool, footer with selected count.
- Row rendering: cursor row prefixed `> `, others `  `; checkbox `[x]`/`[ ]`; label = basename without `_update.sh` (e.g. `grok`, `mini_swe_agent`).
- Key reading (no external deps):

```bash
IFS= read -rsn1 key
if [[ $key == $'\x1b' ]]; then
    IFS= read -rsn2 -t 0.05 seq || true     # lone Esc falls through as cancel
    [[ $seq == '[A' || $seq == 'OA' ]] && move_up
    [[ $seq == '[B' || $seq == 'OB' ]] && move_down
elif [[ $key == ' '  ]]; then toggle_current
elif [[ $key == ''   ]]; then save_and_run      # enter
elif [[ $key == 'q'  ]]; then cancel
fi
```

- Redraw in place: after first draw, move cursor up N rows (`\e[<n>A`) and clear to end of screen (`\e[J`) before each redraw. Highlight via the `> ` marker only.
- Cancel (`q`/`Esc`/Ctrl-C): exit 0 without touching `selection.md` and without running anything.
- Empty selection is legal: print `nothing selected` and exit 0.

### Selection file `selection.md` (git-ignored)

```markdown
# Tools to update — written by aidev_update.sh, safe to edit by hand.
# [x] runs, [ ] does not. Tools missing here default to on.
- [x] claude_update.sh
- [x] codex_update.sh
- [ ] omp_update.sh
```

- Parse rule: `^- \[[ xX]\] <filename>$`. The menu always writes **one line per discovered tool**, so new tools materialize and dead tools disappear on the first save.
- Hand-written comment lines are lost when the menu rewrites the file (documented in the file header; acceptable for a personal tool).

### Wrapper scripts for the former `cmd|` steps (new, 2 lines each)

```bash
#!/usr/bin/env bash
exec claude update        # claude_update.sh (replaces the old 55-line npm updater)
```
- `claude_update.sh` — rewritten to `exec claude update` (current content is the retired npm-based updater; `claude update` is the official command). The legacy script only mentions it in `DISABLED_STEPS`, so nothing there breaks.
- `omp_update.sh` — `exec omp update`.
- `droid_update.sh` — `exec droid update`.
- Retired-by-choice tools (gemini, qwen, amp, ollama, …) keep their scripts; the **selection file** turns them off — no `DISABLED_STEPS` concept in the new script.

### End-to-end flow

interactive run → menu (saved state preloaded) → enter → `selection.md` written → each `[x]` tool runs sequentially under `timeout` → ✓/✗ per tool → summary, exit code.
non-interactive run (pipe/cron — stdin or stdout not a tty) → no menu → run whatever `selection.md` says (or all tools if no file).

## Semantics

- **Ownership/state**: `selection.md` is the new script's only mutable state, owned by the menu; hand edits welcome between runs. The legacy system's `steps.conf` remains exclusively its state.
- **Concurrency**: none in the new script. The legacy lock file stays for `aidev_update_v1.sh` runs only.
- **Failure/recovery**: a failing or hung tool is reported and the run moves on. `timeout --kill-after=10 600` bounds hangs (the repo's history shows npm-based updaters can hang). Ctrl-C during a run kills the current tool and the run (no traps — acceptable, nothing to clean up).
- **Exit codes**: `0` all attempted tools succeeded or nothing selected; `1` at least one tool failed. No other codes.
- **No CLI flags at all.** Unknown arguments are ignored with a one-line hint (2 lines of code, keeps it discoverable).

## Tests — `tests/aidev_update_test.sh`

Sandbox per test: temp dir with a copy of the new script (named `aidev_update.sh`) and fake `ok_*_update.sh` / `fail_*_update.sh` / `hang_*_update.sh` (sleep 30) tools.

1. Non-tty, no `selection.md` → all fake tools run (default on), exit 0, `selection.md` **not** created.
2. `selection.md` with `[ ]` entries → those tools do not run.
3. Menu via `AIDEV_MENU_FORCE=1` + piped keystrokes (`$'\e[B '` moves down and toggles, then `\n`): correct tool toggled; `selection.md` written with one line per tool; a second non-tty run honors it.
4. Menu `q` → nothing runs, `selection.md` unchanged.
5. A failing tool → other tools still run, summary lists it, exit 1.
6. Hung tool killed by `AIDEV_STEP_TIMEOUT=2` → run finishes, that tool marked failed.
7. New tool script added after a save → defaults on next run; a deleted tool's stale `[x]` line is dropped on the next save.
8. **Self-discovery guard**: sandbox contains only the script itself plus fake tools → the run never invokes `aidev_update.sh` (no recursion); `aidev_update_v1.sh` placed in the sandbox is not discovered either.
9. `shellcheck` the new script when available (skip, not fail, when absent).

Acceptance criteria: new suite passes; legacy suite still passes after the one-line path fix; `shellcheck` clean; manual terminal check; new script ≤ ~200 lines; the new README describes only the new system (plus the legacy pointer).

## Non-goals (explicitly out of scope)

- Changing the legacy system's behavior beyond the rename + test path fix.
- Parallel execution, retries, `--require`, kill-after tuning, run logging, log retention, lock, `--only/--skip/--list/--dry-run/--no-menu`, steps.conf DSL — none of these exist in the new script.
- Changing any existing per-package update script (except `claude_update.sh` → wrapper) or `tests/codex_update_test.sh`.
- Windows/posix-sh portability (bash ≥ 4, as today).

## Risks / minor open points

- **Old-file suffix** (`_v1` chosen vs a literal `_v2`): flagged in Summary; one-line rename if the user prefers.
- **Arrow keys on odd terminals**: ESC-sequence read with a 0.05 s follow-up read; lone `Esc` = cancel. Standard terminals (xterm/kitty/gnome-terminal/ssh) all send `\e[A/B`. Acceptable; no ncurses dependency.
- **First run on a fresh clone** (no `selection.md`): every tool defaults on — a one-time re-pick in the menu. (The local machine is seeded during implementation, so in practice the user sees their current 8-tool selection.)
- **Hand comments in `selection.md` are lost on a menu save** — documented in the file header.
- Old logs stay in `logs/` (history preserved, still git-ignored); the new script writes no logs.
- `OPTIMIZATION_SUGGESTIONS.md` and other docs are stale w.r.t. the orchestrator — left untouched.
