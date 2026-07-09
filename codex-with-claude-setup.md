# Codex (GPT-5.5) as a sub-agent inside Claude Code — setup & learnings

This documents how the local `codex` CLI is wired up so Claude Code can delegate
sub-tasks to GPT-5.5, across several accounts, optionally routed through the local
Headroom token-compression proxies. Written so the setup can be recreated from scratch.

- **codex CLI:** `codex-cli 0.143.0-alpha.39` (installed under nvm node v24, `@openai/codex`)
- **Model:** `gpt-5.5`
- **Claude Code plugin:** `codex@openai-codex` (provides `/codex:*` commands and the
  `codex:codex-rescue` subagent)

## Key facts about this codex version

1. **Profile-v2 (file layering).** `codex exec -p NAME` layers
   `~/.codex/NAME.config.toml` on top of the base `~/.codex/config.toml`. It does **not**
   use the old `[profiles.NAME]` TOML blocks. Each profile file can define its own
   `[model_providers.X]`; tables merge over the base config.
2. **Responses API only.** `wire_api = "chat"` is rejected with
   *"`wire_api = "chat"` is no longer supported"*. Every provider must use
   `wire_api = "responses"` (the OpenAI Responses API, `POST /v1/responses`).
3. **Custom providers need the key in the environment.** A `[model_providers.X]` block
   with `env_key = "FOO"` reads `$FOO` from the shell; it cannot fall back to
   `~/.codex/auth.json`. Only the built-in `openai` provider uses `auth.json`.
4. **Azure auth = `api-key` header + `api-version` query.** Azure ignores the
   `Authorization: Bearer` header. Codex sends the header via
   `env_http_headers = { "api-key" = "AZURE_AI_API_KEY" }` and the version via
   `query_params = { api-version = "preview" }`.

## The Headroom instances

Two Headroom (v0.30.0) compression proxies run locally, managed from this directory:

| Port | Script | Backend | Routes to | Handles `/v1/responses`? |
|---|---|---|---|---|
| 8787 | `headroom_start.sh` | `anthropic` (default) | its `/v1` OpenAI passthrough → api.openai.com | ✅ yes |
| 8788 | `headroom_azure_start.sh` | `litellm-azure` | Azure gpt-5.5 deployment | ✅ **only after the fix below** |

Health / routing check:
```bash
curl -s localhost:8788/health | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d["config"]["backend"], d["config"]["openai_api_url"])'
```

### The Azure Responses bug and its fix

**Symptom:** `inf-azure-hr` returned `401 Unauthorized: Incorrect API key ... platform.openai.com`.

**Root cause:** Headroom's `litellm-azure` backend only translates
`/v1/chat/completions`. A `/v1/responses` request (the *only* thing this codex sends)
was **not** handled by litellm and fell through Headroom's OpenAI passthrough to
`api.openai.com`, where the Azure key is invalid → 401.

**Fix (already applied in `headroom_azure_start.sh`):** point Headroom's OpenAI/Codex
passthrough at the Azure deployment so `/v1/responses` reaches Azure:
```bash
OPENAI_TARGET_API_URL="${AZURE_API_BASE%/}/openai/v1"
```
passed into the proxy's env. droid's `chat/completions` path (via litellm-azure) is
unaffected — both endpoints then return 200 against Azure. The `inf-azure-hr` profile
still supplies the `api-key` header + `api-version` query (raw passthrough, no litellm).

## The profiles

Files live in `~/.codex/`. Status as of setup: 4 working, 2 pending a ChatGPT subscription.

| Profile | Route | Auth | Status |
|---|---|---|---|
| `personal` | direct OpenAI | `OPENAI_API_KEY` (or `auth.json`) | ✅ |
| `personal-hr` | OpenAI → Headroom :8787 | `OPENAI_API_KEY` (exported) | ✅ |
| `inf-azure` | direct Azure gpt-5.5 | `AZURE_AI_API_KEY` | ✅ |
| `inf-azure-hr` | Azure → Headroom :8788 | `AZURE_AI_API_KEY` | ✅ |
| `sub` | ChatGPT subscription | `codex login` | ⏳ needs subscription |
| `sub-hr` | ChatGPT sub → :8787 | `codex login` | ⏳ experimental |

### `~/.codex/personal.config.toml`
```toml
model = "gpt-5.5"
model_provider = "openai"
preferred_auth_method = "apikey"
```

### `~/.codex/personal-hr.config.toml`
```toml
model = "gpt-5.5"
model_provider = "openai_hr"

[model_providers.openai_hr]
name = "OpenAI via Headroom (8787)"
base_url = "http://localhost:8787/v1"
env_key = "OPENAI_API_KEY"
wire_api = "responses"
```

### `~/.codex/inf-azure.config.toml`
```toml
model = "gpt-5.5"
model_provider = "azure_inf"

[model_providers.azure_inf]
name = "Azure OpenAI (direct)"
base_url = "https://sven-mos9a6v1-eastus2.cognitiveservices.azure.com/openai/v1"
env_key = "AZURE_AI_API_KEY"
env_http_headers = { "api-key" = "AZURE_AI_API_KEY" }
query_params = { api-version = "preview" }
wire_api = "responses"
```

### `~/.codex/inf-azure-hr.config.toml`
```toml
model = "gpt-5.5"
model_provider = "azure_hr"

[model_providers.azure_hr]
name = "Azure via Headroom (8788)"
base_url = "http://localhost:8788/v1"
env_key = "AZURE_AI_API_KEY"
env_http_headers = { "api-key" = "AZURE_AI_API_KEY" }
query_params = { api-version = "preview" }
wire_api = "responses"
```

### `~/.codex/sub.config.toml` / `sub-hr.config.toml`
```toml
# sub
model = "gpt-5.5"
model_provider = "openai"
preferred_auth_method = "chatgpt"
```
`sub-hr` adds `chatgpt_base_url = "http://localhost:8787/backend-api"` (experimental —
ChatGPT OAuth tokens are validated by OpenAI's backend, so proxying them may not work).
Both require `codex login` (ChatGPT sign-in) after the subscription is purchased.

## Environment variables

These must be present in the shell (e.g. from `~/.zshrc`):
- `OPENAI_API_KEY` — for `personal` (optional; `auth.json` also works) and `personal-hr` (required).
- `AZURE_AI_API_KEY` — for `inf-azure` / `inf-azure-hr`. (Same value as `AZURE_API_KEY`.)
- `AZURE_API_KEY`, `AZURE_API_BASE`, `AZURE_API_VERSION` — required to *start* the :8788
  Headroom instance (`headroom_azure_start.sh`).

## Usage

```bash
# Delegate a task with a chosen account:
codex exec -p personal      "implement X per this plan: ..."
codex exec -p inf-azure-hr  "diagnose the failing test in ..."

# Faster startup for pure code tasks (skip MCP servers), explicit effort:
codex exec -p personal -c mcp_servers='{}' -c model_reasoning_effort='"high"' "..."
```

Inside Claude Code there is also a global skill `codex-gpt5` (in `~/.claude/skills/`)
so "call codex with the personal account through headroom" works from any repo.

**Note on `codex:codex-rescue`:** that subagent forwards to `codex app-server` using the
**default** `config.toml` (= personal/OpenAI) and does *not* honor `-p`. To use a specific
account, call `codex exec -p <profile>` directly.

## Verify any profile

```bash
codex exec -p <profile> --skip-git-repo-check -c mcp_servers='{}' \
  -c model_reasoning_effort='"low"' "Reply with exactly one word: PONG"
```

## Recreate from scratch (checklist)

1. `npm install -g @openai/codex`; confirm `codex --version`.
2. In Claude Code: `/plugin marketplace add openai/codex-plugin-cc`,
   `/plugin install codex@openai-codex`, `/reload-plugins`.
3. Ensure env vars above are exported.
4. Start Headroom: `./headroom_start.sh` and `./headroom_azure_start.sh`
   (the latter includes the `OPENAI_TARGET_API_URL` Azure-Responses fix).
5. Create the six `~/.codex/*.config.toml` profile files shown above.
6. Verify each with the PONG command.
7. For `sub`/`sub-hr`: buy ChatGPT subscription, then `codex login`.

## Troubleshooting

- **`wire_api = "chat"` no longer supported** → change the provider to `wire_api = "responses"`.
- **`inf-azure-hr` 401 with an OpenAI error** → `:8788` is missing the
  `OPENAI_TARGET_API_URL` fix, or wasn't restarted after editing `headroom_azure_start.sh`.
- **`environment variable OPENAI_API_KEY is not set`** on `personal-hr` → export the key;
  custom providers can't read `auth.json`.
- **Azure `api-version` errors** → try a dated version (e.g. `2024-12-01-preview`) instead
  of `preview`, matching `$AZURE_API_VERSION`.
