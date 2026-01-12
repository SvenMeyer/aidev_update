# Release Notes

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
