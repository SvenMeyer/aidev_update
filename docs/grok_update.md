# Grok CLI install method

Canonical install: **official `~/.grok/bin` binary**, installed by `https://x.ai/cli/install.sh` and kept current by `grok update`.

Do **not** install or update via `npm install -g @xai-official/grok`.

The updater is `grok_update.sh`, called from `aidev_update.sh` immediately after the Claude update step.

## What we chose

| Role | Location / command |
|---|---|
| Runtime binary | `~/.grok/bin/grok` (symlink to `grok-<version>`) |
| `agent` alias | `~/.grok/bin/agent` → same versioned binary as `grok` |
| First-time install | `curl -fsSL https://x.ai/cli/install.sh \| bash` |
| Later updates | `grok update`, only when `grok update --check` reports a newer version |
| Channel | `stable` (`installer = "internal"` in `~/.grok/config.toml`) |
| PATH | `export PATH="$HOME/.grok/bin:$PATH"` (written by the official installer) |

`grok_update.sh` prefers `~/.grok/bin/grok` over any other `grok` on `PATH`. If it finds a leftover npm global or extra PATH entries, it warns instead of managing those copies.

## Why not npm

xAI publishes `@xai-official/grok` as an alternative, but it is a delivery wrapper, not a separate CLI:

- The npm `postinstall` still extracts the native binary into `~/.grok/bin/grok-<version>`.
- It also leaves a second ~160MB copy under the current nvm prefix (`.../node_modules/@xai-official/grok/bin/grok-native`).
- Global npm bins are tied to the active Node version. Switching nvm versions makes the npm `grok` vanish from `PATH` while `~/.grok/bin` stays.
- npm 11+ blocks lifecycle scripts unless you pass `--allow-scripts=@xai-official/grok`. Without that flag the package is added but the native binary is not wired up.
- `grok update` already knows how to update an `internal` install. Routing updates through npm adds a second channel that can drift from the binary you actually run.

The official installer plus `grok update` is the path xAI documents first, does not depend on Node, and keeps a single binary.

## Why this showed up as “three groks”

On this machine those were **three PATH entries to the same 1.0.30 binary**, not three versions:

1. `~/.grok/bin/grok` — canonical install (PATH first, from `.zshrc`)
2. `~/.local/bin/grok` — leftover shim from the original curl installer (Jul 2025)
3. nvm global `grok` — the Sep 2025 npm install

The only real stale version was `~/.grok/bin/agent`, which still pointed at the July curl-installer download (`grok 0.2.101` in `~/.grok/downloads/`). npm’s postinstall updates `grok` but not `agent`.

Cleanup kept `~/.grok/bin/grok`, retargeted `agent` at the same versioned file, and removed the npm global, the `~/.local/bin` shims, the old download, and the user-level `allow-scripts=@xai-official/grok` grant.

## Do not

- `npm install -g @xai-official/grok` (with or without `--allow-scripts`)
- `npm update -g @xai-official/grok`
- Uncomment or revive `@vibe-kit/grok-cli` — that is a different, unofficial CLI

If a duplicate comes back, remove it with `npm uninstall -g @xai-official/grok` and confirm `which -a grok` prints only `~/.grok/bin/grok`.
