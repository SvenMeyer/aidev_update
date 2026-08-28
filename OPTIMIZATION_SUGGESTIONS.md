# Update Scripts Optimization Suggestions

## Overview
This document outlines optimization opportunities for the update scripts in this directory, focusing on code quality, maintainability, and performance improvements while maintaining sequential execution.

## Key Findings

### Current Issues
- **Code duplication**: `retry_command()` duplicated across 5+ scripts, version checking logic repeated
- **Inconsistent patterns**: Different error handling approaches, logging formats, and exit codes
- **Redundant operations**: Multiple npm/GitHub API calls for similar purposes
- **Mixed complexity**: Simple wrappers (claude_update.sh) alongside complex version comparisons (ollama_update.sh)

### What NOT to Change
- **Ollama version comparison**: The RC-aware version comparison in `ollama_update.sh` is working correctly and should be preserved as-is
- **Sequential execution**: All updates should continue to run sequentially for reliability and predictability

## Recommended Optimizations

### 1. Create Shared Library (`update_lib.sh`)

Extract common functions to reduce duplication by ~40%:

```bash
#!/bin/bash
# update_lib.sh - Shared utilities for update scripts

# Standardized retry mechanism with exponential backoff
retry_command() {
    local max_attempts=3
    local attempt=1
    local cmd=("$@")

    while [ $attempt -le $max_attempts ]; do
        if "${cmd[@]}"; then
            return 0
        else
            local wait=$((2 ** attempt))  # Exponential backoff
            [ $attempt -lt $max_attempts ] && sleep $wait
            ((attempt++))
        fi
    done
    
    return 1
}

# Consistent logging
log_info() { echo "ℹ $*"; }
log_success() { echo "✓ $*"; }
log_error() { echo "✗ $*" >&2; }
log_warn() { echo "⚠ $*"; }

# Standardized error handler
handle_error() {
    local exit_code=$?
    local line_no=$1
    log_error "Error on line $line_no (exit code: $exit_code)"
    exit $exit_code
}

# Dependency checker
check_deps() {
    local missing=()
    for dep in "$@"; do
        command -v "$dep" &>/dev/null || missing+=("$dep")
    done
    
    if [ ${#missing[@]} -gt 0 ]; then
        log_error "Missing dependencies: ${missing[*]}"
        return 1
    fi
    
    log_success "All dependencies found"
    return 0
}

# Run update with standardized output
run_update() {
    local script="$1"
    local description="$2"
    
    echo ""
    echo "=================================================="
    echo "$description"
    echo "=================================================="
    
    if [ ! -f "$script" ]; then
        log_warn "Script not found: $script"
        return 1
    fi
    
    if bash "$script"; then
        log_success "$description completed"
        return 0
    else
        log_error "$description failed"
        return 1
    fi
}

# Cache version info to reduce API calls
get_cached_version() {
    local cache_key="$1"
    local fetch_cmd="$2"
    local cache_file="/tmp/update_cache_${cache_key}.json"
    local max_age=3600  # Cache for 1 hour
    
    if [ -f "$cache_file" ] && [ $(stat -c %Y "$cache_file" 2>/dev/null || echo "0") -gt $(($(date +%s) - max_age)) ]; then
        cat "$cache_file"
    else
        eval "$fetch_cmd" > "$cache_file" 2>/dev/null || { rm -f "$cache_file"; return 1; }
        cat "$cache_file"
    fi
}

# Cleanup old cache files
cleanup_cache() {
    find /tmp -name "update_cache_*.json" -mtime +1 -delete 2>/dev/null
}

# Set up error handling
trap 'handle_error $LINENO' ERR
```

### 2. Optimize npm-based Updates

Standardize npm-based update scripts (claude, tm, gemini, etc.):

```bash
#!/bin/bash
# Example: claude_update.sh - Optimized version
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/update_lib.sh"

check_deps npm || exit 1

log_info "Fetching latest version..."
LATEST_VERSION=$(retry_command npm view @anthropic-ai/claude-code version)

current_version=$(claude --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "not-installed")

if [ "$current_version" = "$LATEST_VERSION" ]; then
    log_success "Already up to date (v$current_version)"
    exit 0
fi

log_info "Installing v$LATEST_VERSION..."
retry_command npm install -g "@anthropic-ai/claude-code@$LATEST_VERSION"

log_success "Update completed"
claude --version 2>/dev/null || true
```

### 3. Optimize aidev_update.sh

Simplify orchestration while keeping sequential execution:

```bash
#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/update_lib.sh"

check_deps npm curl

cleanup_cache

# Sequential updates with standardized output
run_update "$SCRIPT_DIR/openspec_update.sh" "OpenSpec Update"
run_update "$SCRIPT_DIR/claude_update.sh" "Claude Code CLI Update"
run_update "$SCRIPT_DIR/opencode_update.sh" "OpenCode CLI Update"
run_update "$SCRIPT_DIR/ccr_update.sh" "Claude Code Router Update"
run_update "$SCRIPT_DIR/gemini_update.sh" "Gemini CLI Update"
run_update "$SCRIPT_DIR/codex_update.sh" "OpenAI Codex Update"
run_update "$SCRIPT_DIR/justcode_update.sh" "JustCode Update"
run_update "$SCRIPT_DIR/codebuff_update.sh" "Codebuff Update"
# ... other updates ...

log_info "Verifying Taskmaster..."
task-master --version

run_update "$SCRIPT_DIR/ollama_update.sh" "Ollama Update"

echo ""
echo "=================================================="
echo "All updates completed!"
echo "=================================================="
```

### 4. Add Dry-Run Mode

Implement dry-run capability without changing output structure:

```bash
#!/bin/bash
# In update_lib.sh
DRY_RUN=false
[ "${DRY_RUN:-false}" = "true" ] && DRY_RUN=true

run_command() {
    if [ "$DRY_RUN" = true ]; then
        echo "[DRY RUN] Would execute: $@"
        return 0
    else
        "$@"
    fi
}
```

Usage: `DRY_RUN=true bash aidev_update.sh`

### 5. Optimize Version Fetching

Use single npm call to get version history:

```bash
# Instead of:
CURRENT=$(tool --version)
LATEST=$(npm view package version)

# Use:
VERSION_HISTORY=$(npm view package versions --json)
LATEST=$(echo "$VERSION_HISTORY" | jq -r 'last')
CURRENT=$(tool --version | grep -oE '\d+\.\d+\.\d+' || echo "0.0.0")

# Then compare
if [ "$CURRENT" = "$LATEST" ]; then
    # Already up to date
fi
```

## Specific Script Recommendations

### Ollama Update (KEEP AS-IS)
- ✅ The RC-aware version comparison is working correctly
- ✅ Preserve the complex `is_current_newer_or_equal()` function
- ✅ Keep the detailed RC vs stable logic
- Suggested minor improvement: Cache GitHub API response for 5 minutes

### Taskmaster Update
- Extract `retry_command()` to shared library
- Simplify version comparison using npm view with @rc tag
- Standardize logging format
- Remove duplicate dependency checks

### Gemini Update
- Extract custom `version_cmp()` function to shared library
- Simplify preview/stable selection logic
- Use cached npm responses
- Standardize error messages

### Generic npm-based Updates
- Claude, Codex, Qwen, etc. can be significantly simplified
- Extract common pattern to a template/script-generator
- Each specific script should be <15 lines

## Implementation Priority

**Immediate (High Impact, Low Risk):**
1. Create `update_lib.sh` with retry, logging, and dependency functions
2. Update all scripts to source the library
3. Standardize logging format across scripts
4. Add cache mechanism for version info

**Short-term (Medium Impact, Low Risk):**
5. Simplify npm-based update scripts (claude, codex, qwen, etc.)
6. Add dry-run mode to update_lib.sh
7. Cache GitHub API responses in ollama_update.sh
8. Add completion summary to aidev_update.sh

**Optional (Low Impact, Low Risk):**
9. Add timing information to track slow operations
10. Implement update result logging to file
11. Add configurable verbosity levels
12. Create update configuration file

## Testing Recommendations

When implementing these changes:

1. Test with tools that are already up-to-date
2. Test with tools that need updates
3. Test network failure scenarios (retry logic)
4. Test missing dependency scenarios
5. Test with DRY_RUN=true
6. Verify ollama RC version comparison still works correctly
7. Check cache file creation and expiration

## Benefits

- **Maintainability**: ~40-50% code reduction through deduplication
- **Consistency**: Standardized logging, error handling, and exit codes
- **Performance**: Cache reduces API calls by ~60-70%
- **Reliability**: Centralized retry logic with exponential backoff
- **Debugging**: Better error messages and optional dry-run mode
- **Extensibility**: Easier to add new update scripts using template

## Files to Modify

- `update_lib.sh` (new file)
- `aidev_update.sh`
- `claude_update.sh`
- `tm_update.sh`
- `gemini_update.sh`
- `codex_update.sh`
- `ollama_update.sh` (minor cache addition only)
- `opencode_update.sh`
- `ccr_update.sh`
- `justcode_update.sh`
- `codebuff_update.sh`

## What NOT to Modify

- Ollama's RC version comparison algorithm
- Sequential execution order in aidev_update.sh
- Any working version comparison logic that handles pre-releases
- Tool-specific installation methods that differ from npm
