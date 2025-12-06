#!/bin/bash
set -eo pipefail

echo "CLIProxyAPI Update"

# Check installation status by looking for the binary in standard locations
CLI_PROXY_API_PATH="$HOME/cliproxyapi/cli-proxy-api"
if [ -f "$CLI_PROXY_API_PATH" ]; then
    CURRENT_INSTALLED=true
    echo "CLIProxyAPI is currently installed"
elif command -v cliproxyapi >/dev/null 2>&1; then
    CURRENT_INSTALLED=true
    echo "CLIProxyAPI is currently installed (in PATH)"
else
    CURRENT_INSTALLED=false
    echo "CLIProxyAPI is not installed"
fi

# Check if service exists and is running
if systemctl --user list-unit-files | grep -q "cliproxyapi.service"; then
    SERVICE_EXISTS=true
    if systemctl --user is-active --quiet cliproxyapi.service 2>/dev/null; then
        SERVICE_RUNNING=true
        echo "CLIProxyAPI service is running"
    else
        SERVICE_RUNNING=false
        echo "CLIProxyAPI service exists but is not running"
    fi
else
    SERVICE_EXISTS=false
    echo "CLIProxyAPI service does not exist"
fi

# Get current version if possible and extract just the version number
CURRENT_VERSION="unknown"
if [ -f "$CLI_PROXY_API_PATH" ]; then
    cd "$(dirname "$CLI_PROXY_API_PATH")"
    VERSION_OUTPUT=$("./cli-proxy-api" --version 2>/dev/null || echo "unknown")
    # Extract version number from output like "CLIProxyAPI Version: 6.5.48, Commit: ..."
    CURRENT_VERSION=$(echo "$VERSION_OUTPUT" | grep -o 'Version: [0-9]\+\.[0-9]\+\.[0-9]\+' | sed 's/Version: //' || echo "unknown")
    echo "Current version: $CURRENT_VERSION"
elif command -v cliproxyapi >/dev/null 2>&1; then
    VERSION_OUTPUT=$(cliproxyapi --version 2>/dev/null || echo "unknown")
    CURRENT_VERSION=$(echo "$VERSION_OUTPUT" | grep -o 'Version: [0-9]\+\.[0-9]\+\.[0-9]\+' | sed 's/Version: //' || echo "unknown")
    echo "Current version: $CURRENT_VERSION"
fi

# Check if we can reach the installer endpoint
echo "Checking for updates..."
if ! curl -fsSL https://raw.githubusercontent.com/brokechubb/cliproxyapi-installer/refs/heads/master/cliproxyapi-installer >/dev/null 2>&1; then
    echo "Could not reach CLIProxyAPI installer. Skipping update."
    exit 0
fi

# Try to get latest version from local CLIProxyAPI service first (most reliable)
LATEST_VERSION="unknown"
if [ "$SERVICE_RUNNING" = true ]; then
    echo "Checking latest version from local CLIProxyAPI service..."
    # Try the local /v0/management/latest-version endpoint with authentication
    LATEST_VERSION=$(curl -s -H "Authorization: Bearer cliproxyapi-management-2025" -H "Content-Type: application/json" http://localhost:8317/v0/management/latest-version 2>/dev/null | python3 -c "import sys, json; print(json.load(sys.stdin).get('latest-version', 'unknown').lstrip('v'))" || echo "unknown")
    
    if [ "$LATEST_VERSION" != "unknown" ]; then
        echo "✓ Latest version from local service: $LATEST_VERSION"
    else
        echo "Local service authentication failed, trying fallback methods..."
    fi
fi

# If local service doesn't have the endpoint or failed, try GitHub API
if [ "$LATEST_VERSION" = "unknown" ]; then
    echo "Checking latest version from GitHub API..."
    LATEST_VERSION=$(curl -s https://api.github.com/repos/brokechubb/CLIProxyAPI/releases/latest 2>/dev/null | grep -o '"tag_name": "[^"]*' | sed 's/"tag_name": "//' | sed 's/"//' || echo "unknown")
fi

# If that fails, try the installer endpoint as backup
if [ "$LATEST_VERSION" = "unknown" ]; then
    echo "Trying installer script version detection..."
    # Try to get version info from the installer script itself
    LATEST_VERSION=$(curl -s https://raw.githubusercontent.com/brokechubb/cliproxyapi-installer/refs/heads/master/cliproxyapi-installer 2>/dev/null | grep -o 'Latest version: [0-9]\+\.[0-9]\+\.[0-9]\+' | sed 's/Latest version: //' || echo "unknown")
fi

if [ "$LATEST_VERSION" = "unknown" ]; then
    echo "Could not determine latest version. Proceeding with update check anyway."
else
    echo "Latest version: $LATEST_VERSION"
fi

# Version comparison function
version_compare() {
    local current="$1"
    local latest="$2"
    
    if [ "$current" = "unknown" ] || [ "$latest" = "unknown" ]; then
        return 1  # Can't compare, proceed with update
    fi
    
    # Use sort -V for proper version comparison
    if [ "$current" = "$latest" ]; then
        return 0  # Same version, no update needed
    elif [ "$(printf "%s\n%s\n" "$current" "$latest" | sort -V | head -n1)" = "$current" ]; then
        return 1  # Current is older, update needed
    else
        return 0  # Current is newer or same, no update needed
    fi
}

# Check if update is needed
if [ "$CURRENT_VERSION" != "unknown" ] && [ "$LATEST_VERSION" != "unknown" ]; then
    echo "DEBUG: Current version: '$CURRENT_VERSION', Latest version: '$LATEST_VERSION'"
    if version_compare "$CURRENT_VERSION" "$LATEST_VERSION"; then
        echo "✓ CLIProxyAPI is already up to date (version $CURRENT_VERSION)"
        exit 0
    else
        echo "Update required: $CURRENT_VERSION -> $LATEST_VERSION"
        echo "DEBUG: version_compare returned: $?"
    fi
else
    echo "Could not determine version information. Proceeding with update check..."
fi

# If not installed at all, we should install it
if [ "$CURRENT_INSTALLED" = false ] && [ "$SERVICE_EXISTS" = false ]; then
    echo "CLIProxyAPI is not installed. Installing now..."
    
    # Backup any existing config
    if [ -f "/home/sum/Scripts/CLIProxyAPI/config.yaml" ]; then
        echo "Backing up existing configuration..."
        cp /home/sum/Scripts/CLIProxyAPI/config.yaml ~/cliproxyapi-backup-config.yaml
    fi
    
    # Run the installer
    echo "Running CLIProxyAPI installer..."
    if curl -fsSL https://raw.githubusercontent.com/brokechubb/cliproxyapi-installer/refs/heads/master/cliproxyapi-installer | bash; then
        echo "✓ CLIProxyAPI installed successfully"
        
        # Restore configuration if backup exists
        if [ -f ~/cliproxyapi-backup-config.yaml ]; then
            echo "Restoring configuration..."
            cp ~/cliproxyapi-backup-config.yaml ~/cliproxyapi/config.yaml
            echo "Configuration restored. You may need to restart the service:"
            echo "systemctl --user restart cliproxyapi.service"
        fi
        
        # Enable and start the service
        echo "Enabling and starting CLIProxyAPI service..."
        systemctl --user enable cliproxyapi.service 2>/dev/null || true
        systemctl --user start cliproxyapi.service 2>/dev/null || true
        
        echo "✓ CLIProxyAPI installation complete"
    else
        echo "✗ CLIProxyAPI installation failed" >&2
        exit 1
    fi
    
    exit 0
fi

# For existing installations, proceed with update
echo "Updating CLIProxyAPI..."

# Stop the service if it's running
if [ "$SERVICE_RUNNING" = true ]; then
    echo "Stopping CLIProxyAPI service..."
    systemctl --user stop cliproxyapi.service
fi

# Run the installer (which handles backups and updates)
echo "Running CLIProxyAPI installer for update..."
if curl -fsSL https://raw.githubusercontent.com/brokechubb/cliproxyapi-installer/refs/heads/master/cliproxyapi-installer | bash; then
    echo "✓ CLIProxyAPI updated successfully"
    
    # Start the service
    echo "Starting CLIProxyAPI service..."
    systemctl --user start cliproxyapi.service
    
    # Check if service started successfully
    sleep 2
    if systemctl --user is-active --quiet cliproxyapi.service; then
        echo "✓ CLIProxyAPI service is running"
        
        # Get new version
        if [ -f "$HOME/cliproxyapi/cli-proxy-api" ]; then
            cd "$HOME/cliproxyapi"
            NEW_VERSION=$("./cli-proxy-api" --version 2>/dev/null || echo "unknown")
            echo "Updated to version: $NEW_VERSION"
        fi
    else
        echo "⚠ CLIProxyAPI service failed to start. Check logs with:"
        echo "journalctl --user -u cliproxyapi.service -f"
    fi
else
    echo "✗ CLIProxyAPI update failed" >&2
    
    # Try to start the old version if update failed
    if [ "$SERVICE_RUNNING" = true ]; then
        echo "Attempting to restart previous version..."
        systemctl --user start cliproxyapi.service 2>/dev/null || true
    fi
    
    exit 1
fi

echo "✓ CLIProxyAPI update completed"
