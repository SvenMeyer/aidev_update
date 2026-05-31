
#!/bin/bash

# Note: We don't use 'set -e' here so that individual update failures don't stop the entire script

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to run update with error handling
run_update() {
    local script_name="$1"
    local description="$2"

    echo ""
    echo "====================================="
    echo "$description"
    echo "====================================="

    if [ -f "$script_name" ]; then
        if bash "$script_name"; then
            echo "✓ $description completed successfully"
        else
            echo "✗ $description failed"
            return 1
        fi
    else
        echo "⚠ Update script not found: $script_name"
        return 1
    fi
}

## visual separators will be echoed inline below

# Check dependencies
echo "Checking dependencies..."
missing_deps=()

if ! command_exists npm; then
    missing_deps+=("npm")
fi

if ! command_exists curl; then
    missing_deps+=("curl")
fi

if [ ${#missing_deps[@]} -ne 0 ]; then
    echo "❌ Missing required dependencies: ${missing_deps[*]}"
    echo "Please install the missing dependencies and try again."
    exit 1
fi

echo "✓ All dependencies found"
echo ""


echo "------------------------------------------------------------"
run_update "$SCRIPT_DIR/openspec_update.sh" "OpenSpec Update"

echo "------------------------------------------------------------"
run_update "$SCRIPT_DIR/mini_swe_agent_update.sh" "mini-swe-agent Update"

echo "------------------------------------------------------------"
# run_update "$SCRIPT_DIR/claude_update.sh" "Claude Code CLI Update"

echo "Claude Code CLI Update"
claude update

echo "------------------------------------------------------------"
echo "DROID CLI Update"
droid update

echo "------------------------------------------------------------"
echo "Copilot Update"
copilot update

echo "------------------------------------------------------------"
echo "Codex Update"
run_update "$SCRIPT_DIR/codex_update.sh" "OpenAI Codex Update"

# echo "------------------------------------------------------------"
# run_update "$SCRIPT_DIR/opencode_update.sh" "OpenCode CLI Update"
#
# echo "------------------------------------------------------------"
# run_update "$SCRIPT_DIR/ccr_update.sh" "Claude Code Router Update"
#
# echo "------------------------------------------------------------"
# run_update "$SCRIPT_DIR/gemini_update.sh" "Gemini CLI Update"

# https://www.npmjs.com/package/@vibe-kit/grok-cli
#echo "Grok CLI"
#grok --version
#npm install -g @vibe-kit/grok-cli
#grok --version
#echo "-------------------------------------"

# echo "------------------------------------------------------------"
# run_update "$SCRIPT_DIR/qwen_update.sh" "Qwen Code Update"

# echo "------------------------------------------------------------"
# run_update "$SCRIPT_DIR/amp_update.sh" "Amp Code Update"

# echo "------------------------------------------------------------"
# run_update "$SCRIPT_DIR/llxprt_update.sh" "LLxprt Code Update"

# echo "------------------------------------------------------------"
# run_update "$SCRIPT_DIR/justcode_update.sh" "JustCode Update"

# echo "------------------------------------------------------------"
# run_update "$SCRIPT_DIR/codebuff_update.sh" "Codebuff Update"

echo "------------------------------------------------------------"
run_update "$SCRIPT_DIR/tm_update.sh" "Taskmaster Update"
task-master --version

echo "------------------------------------------------------------"
run_update "$SCRIPT_DIR/cliproxyapi_update.sh" "CLIProxyAPI Update"

echo "------------------------------------------------------------"
run_update "$SCRIPT_DIR/antigravity_update.sh" "Google Antigravity Update"

echo "------------------------------------------------------------"
run_update "$SCRIPT_DIR/entire_update.sh" "Entire Update"

echo "------------------------------------------------------------"
run_update "$SCRIPT_DIR/headroom_update.sh" "Headroom Update"

# echo "------------------------------------------------------------"
# run_update "$SCRIPT_DIR/ollama_update.sh" "Ollama Update"

echo "------------------------------------------------------------"
echo "Kilo Update"
kilo upgrade

echo "------------------------------------------------------------"
run_update "$SCRIPT_DIR/beads_update.sh" "Beads Update"

echo "------------------------------------------------------------"
run_update "$SCRIPT_DIR/gastown_update.sh" "Gastown Update"

echo "------------------------------------------------------------"
run_update "$SCRIPT_DIR/gastown_gui_update.sh" "Gastown GUI Update"

echo ""
echo "====================================="
echo "All updates completed!"
echo "====================================="
