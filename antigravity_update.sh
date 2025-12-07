#!/bin/bash
#
# Google Antigravity installer/updater for Manjaro Linux KDE
# Downloads the latest version and sets up desktop integration
#

set -e

# Configuration
INSTALL_DIR="$HOME/.local/share/antigravity"
BIN_LINK="$HOME/.local/bin/antigravity"
DESKTOP_FILE="$HOME/.local/share/applications/antigravity.desktop"
VERSION_FILE="$INSTALL_DIR/.version"
DOWNLOAD_PAGE="https://antigravity.google/download/linux"
TEMP_DIR=$(mktemp -d)

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

cleanup() {
    rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Get the current installed version
get_installed_version() {
    if [[ -f "$VERSION_FILE" ]]; then
        cat "$VERSION_FILE"
    else
        echo ""
    fi
}

# Fetch the latest version and download URL from the website
get_latest_info() {
    # Get the main JS file name from the download page
    local main_js=$(curl -sL --compressed "$DOWNLOAD_PAGE" | grep -oE 'main-[A-Z0-9]+\.js' | head -1)

    if [[ -z "$main_js" ]]; then
        log_error "Could not find main JS file"
        exit 1
    fi

    # Extract Linux download URL from the JS file
    local download_url=$(curl -sL --compressed "https://antigravity.google/$main_js" | \
        grep -oE 'https://edgedl[^"'\'']+linux-x64/Antigravity\.tar\.gz' | head -1)

    # If the URL pattern doesn't have slash before linux, try the alternate pattern
    if [[ -z "$download_url" ]]; then
        download_url=$(curl -sL --compressed "https://antigravity.google/$main_js" | \
            grep -oE 'https://edgedl[^"'\'']+Antigravity\.tar\.gz' | grep -i linux | head -1)
    fi

    # Fix malformed URL: the JS sometimes has "1.11.14-5763785964257280linux-x64" instead of ".../linux-x64"
    # Add missing slash before linux-x64 if needed
    download_url=$(echo "$download_url" | sed 's/\([0-9]\)linux-x64/\1\/linux-x64/')

    if [[ -z "$download_url" ]]; then
        log_error "Could not find download URL"
        exit 1
    fi

    # Extract version from URL (format: X.X.X-buildnumber)
    local version=$(echo "$download_url" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+-[0-9]+')

    if [[ -z "$version" ]]; then
        log_error "Could not extract version from URL"
        exit 1
    fi

    echo "$version|$download_url"
}

# Compare versions (returns 0 if remote is newer, 1 otherwise)
is_newer_version() {
    local installed="$1"
    local remote="$2"

    if [[ -z "$installed" ]]; then
        return 0  # Not installed, so remote is "newer"
    fi

    if [[ "$installed" == "$remote" ]]; then
        return 1  # Same version
    fi

    # Extract semantic version part (before the dash)
    local installed_sem="${installed%%-*}"
    local remote_sem="${remote%%-*}"

    # Compare semantic versions
    if [[ "$(printf '%s\n' "$installed_sem" "$remote_sem" | sort -V | tail -n1)" == "$remote_sem" && "$installed_sem" != "$remote_sem" ]]; then
        return 0  # Remote is newer
    fi

    # If semantic versions are same, compare build numbers
    local installed_build="${installed##*-}"
    local remote_build="${remote##*-}"

    if [[ "$remote_build" -gt "$installed_build" ]] 2>/dev/null; then
        return 0  # Remote build is newer
    fi

    return 1  # Installed is same or newer
}

# Download and extract
download_and_extract() {
    local url="$1"
    local archive="$TEMP_DIR/antigravity.tar.gz"

    log_info "Downloading from: $url"

    if ! curl -L --progress-bar -o "$archive" "$url"; then
        log_error "Download failed"
        exit 1
    fi

    log_info "Extracting archive..."

    # Remove old installation if exists
    if [[ -d "$INSTALL_DIR" ]]; then
        rm -rf "$INSTALL_DIR"
    fi

    # Create install directory
    mkdir -p "$INSTALL_DIR"

    # Extract
    tar -xzf "$archive" -C "$INSTALL_DIR" --strip-components=1 2>/dev/null || \
    tar -xzf "$archive" -C "$INSTALL_DIR" 2>/dev/null

    # Handle case where archive extracts to a subdirectory
    if [[ ! -f "$INSTALL_DIR/antigravity" && ! -f "$INSTALL_DIR/Antigravity" ]]; then
        local subdir=$(find "$INSTALL_DIR" -maxdepth 1 -type d ! -path "$INSTALL_DIR" | head -1)
        if [[ -n "$subdir" ]]; then
            mv "$subdir"/* "$INSTALL_DIR"/ 2>/dev/null || true
            rmdir "$subdir" 2>/dev/null || true
        fi
    fi
}

# Create symlink in PATH
create_symlink() {
    mkdir -p "$(dirname "$BIN_LINK")"

    # Find the executable
    local executable=""
    for name in antigravity Antigravity; do
        if [[ -f "$INSTALL_DIR/$name" ]]; then
            executable="$INSTALL_DIR/$name"
            break
        fi
    done

    if [[ -z "$executable" ]]; then
        # Try to find any executable
        executable=$(find "$INSTALL_DIR" -maxdepth 2 -type f -executable -name "*ntigravity*" | head -1)
    fi

    if [[ -n "$executable" ]]; then
        chmod +x "$executable"
        ln -sf "$executable" "$BIN_LINK"
        log_info "Created symlink: $BIN_LINK -> $executable"
    else
        log_warn "Could not find executable to symlink"
    fi
}

# Create .desktop file for KDE integration
create_desktop_file() {
    mkdir -p "$(dirname "$DESKTOP_FILE")"

    # Find the executable
    local executable=""
    for name in antigravity Antigravity; do
        if [[ -f "$INSTALL_DIR/$name" ]]; then
            executable="$INSTALL_DIR/$name"
            break
        fi
    done

    if [[ -z "$executable" ]]; then
        executable=$(find "$INSTALL_DIR" -maxdepth 2 -type f -executable -name "*ntigravity*" | head -1)
    fi

    if [[ -z "$executable" ]]; then
        log_warn "Could not find executable for desktop file"
        return
    fi

    # Find icon
    local icon=""
    for ext in png svg ico; do
        local found=$(find "$INSTALL_DIR" -maxdepth 3 -type f -name "*.${ext}" | head -1)
        if [[ -n "$found" ]]; then
            icon="$found"
            break
        fi
    done

    # Use a default icon name if no icon found
    if [[ -z "$icon" ]]; then
        icon="applications-science"
    fi

    cat > "$DESKTOP_FILE" << EOF
[Desktop Entry]
Name=Google Antigravity
Comment=Google Antigravity - Build the new way
Exec=$executable %U
Icon=$icon
Type=Application
Categories=Development;Utility;
Terminal=false
StartupNotify=true
StartupWMClass=Antigravity
MimeType=x-scheme-handler/antigravity;
EOF

    chmod +x "$DESKTOP_FILE"
    log_info "Created desktop file: $DESKTOP_FILE"

    # Update desktop database
    if command -v update-desktop-database &> /dev/null; then
        update-desktop-database "$(dirname "$DESKTOP_FILE")" 2>/dev/null || true
    fi

    # Register antigravity:// protocol handler for OAuth callbacks
    if command -v xdg-mime &> /dev/null; then
        xdg-mime default antigravity.desktop x-scheme-handler/antigravity 2>/dev/null || true
        log_info "Registered antigravity:// protocol handler"
    fi
}

# Save version info
save_version() {
    local version="$1"
    echo "$version" > "$VERSION_FILE"
}

# Main
main() {
    log_info "Google Antigravity Installer/Updater for Manjaro Linux"
    echo ""

    # Ensure ~/.local/bin is in PATH
    if [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
        log_warn "~/.local/bin is not in your PATH"
        log_warn "Add this to your ~/.bashrc or ~/.zshrc:"
        echo '  export PATH="$HOME/.local/bin:$PATH"'
        echo ""
    fi

    # Get installed version
    local installed_version=$(get_installed_version)
    if [[ -n "$installed_version" ]]; then
        log_info "Installed version: $installed_version"
    else
        log_info "Antigravity is not currently installed"
    fi

    # Get latest version info
    local latest_info=$(get_latest_info)
    local latest_version="${latest_info%%|*}"
    local download_url="${latest_info##*|}"

    log_info "Latest version: $latest_version"

    # Check if update needed
    if is_newer_version "$installed_version" "$latest_version"; then
        log_info "New version available! Proceeding with installation..."
        echo ""

        download_and_extract "$download_url"
        create_symlink
        create_desktop_file
        save_version "$latest_version"

        echo ""
        log_info "Installation complete!"
        log_info "You can run 'antigravity' from the terminal or find it in your application menu"
    else
        log_info "You already have the latest version installed"
    fi
}

main "$@"
