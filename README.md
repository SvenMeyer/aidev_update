# AI Dev Tools Update Script

A comprehensive update script for managing multiple AI-powered development CLI tools.

> **Note:** This repository has only been tested on "plain" Linux (Manjaro Linux).

## Overview

`aidev_update.sh` is a unified update manager that keeps your AI development tools up-to-date. It orchestrates updates for various AI coding assistants and related tools through a single command.

## Prerequisites

- **npm** (Node Package Manager)
- **curl** (for downloading updates)
- **bash** (shell environment)
- **pipx** (for the Python-based tools: mini-swe-agent, headroom)
- **python3** (used by the pipx-based updaters)

`aidev_update.sh` checks for **npm** and **curl** before running and exits with an error if either is missing. The remaining tools are checked by the individual update scripts that need them, which fail with an actionable message if one is absent.

## Usage

```bash
./aidev_update.sh
```

The script will automatically:
1. Verify all required dependencies
2. Update each tool in sequence
3. Display version information before and after updates
4. Report success or failure for each tool

## Tools Managed

### Direct npm Installations
- **OpenCode CLI** - `opencode-ai@latest`
- **Qwen Code** - `@qwen-code/qwen-code@preview`
- **llxprt-code** - `@vybestack/llxprt-code@latest` (Gemini CLI fork)
- **justcode** - `@just-every/code`
- **codebuff** - `codebuff`

### External Update Scripts
- **Claude Code CLI** - `claude_update.sh`
- **Claude Code Router** - `ccr_update.sh`
- **CLIProxyAPI** - `cliproxyapi_update.sh`
- **Gemini CLI** - `gemini_update.sh`
- **OpenAI Codex** - `codex_update.sh`
- **OpenSpec** - `openspec_update.sh`
- **Amp Code** - `amp_update.sh`
- **Taskmaster** - `tm_update.sh`
- **Ollama** - `ollama_update.sh`
- **mini-swe-agent** - `mini_swe_agent_update.sh`

## Directory Structure

```
aidev_update/
├── aidev_update.sh             # Main orchestration script
├── claude_update.sh            # Claude CLI updater
├── codex_update.sh             # OpenAI Codex updater
├── ccr_update.sh               # Claude Code Router updater
├── cliproxyapi_update.sh       # CLIProxyAPI updater
├── gemini_update.sh            # Gemini CLI updater
├── gemini_install.sh           # Gemini CLI installer
├── openspec_update.sh          # OpenSpec updater
├── amp_update.sh               # Amp Code updater
├── tm_update.sh                # Taskmaster updater
├── ollama_update.sh            # Ollama updater
├── ollama_install.sh           # Ollama installer
├── ollama_install_cached.sh    # Ollama installer (cached version)
├── codebuff_update.sh          # Codebuff updater
├── llxprt_update.sh            # llxprt-code updater
├── opencode_update.sh          # OpenCode CLI updater
├── justcode_update.sh          # justcode updater
├── mini_swe_agent_update.sh    # mini-swe-agent installer/updater
└── qwen_update.sh              # Qwen Code updater
```

## Features

- **Dependency Checking** - Validates required tools before execution
- **Error Handling** - Continues execution even if individual updates fail
- **Visual Feedback** - Clear status indicators (✓, ✗, ⚠) for each operation
- **Version Reporting** - Shows before/after versions for npm-installed tools
- **Modular Design** - Uses separate update scripts for complex tools

## Error Handling

- If dependencies are missing, the script exits with an error message
- If an individual update script fails, it logs the failure and continues
- If an npm package installation fails, it reports "Installation failed" for that tool

## Exit Codes

- `0` - All operations completed (individual tools may have failed)
- `1` - Missing dependencies or critical error
