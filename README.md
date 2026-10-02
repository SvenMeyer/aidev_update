# aidev_update

Updates the AI dev tools on this machine: one `*_update.sh` per tool, and one
small orchestrator that runs the selected ones one after the other.

## Run

```bash
./aidev_update.sh
```

An interactive run opens a menu first:

- `↑`/`↓` move the cursor
- `space` toggles the tool under the cursor
- `enter` saves the selection and starts the updates
- `q` or `Esc` cancels without changing anything

The choice is stored in `selection.md` (git-ignored) and preselected the next
time. A non-interactive run (piped, cron) skips the menu and runs the saved
selection. Tools missing from the file default to on.

Each tool runs under `timeout` (10-minute cap) so one hung updater cannot
block the rest; a failing tool is reported and the run continues. The exit
code is `1` when any tool failed, `0` otherwise.

## Adding and removing tools

- **Add**: drop a `mytool_update.sh` next to `aidev_update.sh`. It appears in
  the menu on the next run, on by default.
- **Remove**: delete its script. Its line disappears from `selection.md` on
  the next menu save.
- `selection.md` is plain markdown checkboxes and safe to edit by hand:

  ```
  - [x] grok_update.sh
  - [ ] ollama_update.sh
  ```

## Tests

```bash
./tests/aidev_update_test.sh     # v2 orchestrator
./tests/orchestrator_test.sh     # legacy orchestrator (aidev_update_v1.sh)
./tests/codex_update_test.sh     # codex updater
```

## Legacy

The previous feature-rich orchestrator (parallel jobs, retries, run logging,
filters) is kept unchanged as `aidev_update_v1.sh`, together with its
`aidev_select.sh` selector and `steps.conf` state file. The v2 design and
the reasoning behind the rewrite are documented in `specs_v2.md`.
