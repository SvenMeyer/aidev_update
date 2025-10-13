#!/bin/bash

# Basic retry function
retry_command() {
    local max_attempts=2
    local attempt=1

    while [ $attempt -le $max_attempts ]; do
        if "$@"; then
            return 0
        else
            echo "Attempt $attempt failed. Retrying..."
            ((attempt++))
            sleep 2
        fi
    done

    echo "All attempts failed."
    return 1
}

echo "Ollama"
CURRENT_VERSION=$(ollama --version 2>&1 | grep -E "(client|ollama) version is" | awk '{print $NF}' || echo "not installed")
echo "Current version: $CURRENT_VERSION"

# Check if there's a newer version available
echo "Fetching latest version information..."
LATEST_VERSION=$(retry_command curl -s https://api.github.com/repos/ollama/ollama/releases/latest | grep -o '"tag_name": "[^"]*' | sed -E 's/"tag_name": "v?//')
echo "Latest version: $LATEST_VERSION"

if [ "$CURRENT_VERSION" = "$LATEST_VERSION" ]; then
    echo "✓ Ollama is already up to date"
elif [ "$CURRENT_VERSION" = "not installed" ]; then
    echo "Installing Ollama (version $LATEST_VERSION)"
else
    # Check if current version is newer (pre-release) than latest stable
    if [[ "$CURRENT_VERSION" > "$LATEST_VERSION" ]]; then
        echo "✓ Ollama version $CURRENT_VERSION is newer than the latest stable release ($LATEST_VERSION)"
        echo "You're running a pre-release version. Skipping update."
        exit 0
    else
        echo "Updating Ollama from $CURRENT_VERSION to $LATEST_VERSION"
    fi

    # Set pre-release flag (enable by default like the original script)
    INCLUDE_PRE_RELEASE=true

    set -eu

    red="$( (/usr/bin/tput bold || :; /usr/bin/tput setaf 1 || :) 2>&-)"
    plain="$( (/usr/bin/tput sgr0 || :) 2>&-)"

    status() { echo ">>> $*" >&2; }
    error() { echo "${red}ERROR:${plain} $*"; exit 1; }
    warning() { echo "${red}WARNING:${plain} $*"; }

    TEMP_DIR=$(mktemp -d)
    cleanup() {
        rm -rf $TEMP_DIR
        # Restore backup if installation failed
        if [ -n "$BACKUP_DIR" ] && [ -d "$BACKUP_DIR" ] && [ ! -d "$OLLAMA_INSTALL_DIR/lib/ollama" ]; then
            status "Restoring backup after installation failure"
            $SUDO mv "$BACKUP_DIR" "$OLLAMA_INSTALL_DIR/lib/ollama"
        fi
    }
    trap cleanup EXIT

    available() { command -v $1 >/dev/null; }
    require() {
        local MISSING=''
        for TOOL in $*; do
            if ! available $TOOL; then
                MISSING="$MISSING $TOOL"
            fi
        done
        echo $MISSING
    }

    [ "$(uname -s)" = "Linux" ] || error 'This script is intended to run on Linux only.'

    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64) ARCH="amd64" ;;
        aarch64|arm64) ARCH="arm64" ;;
        *) error "Unsupported architecture: $ARCH" ;;
    esac

    IS_WSL2=false

    KERN=$(uname -r)
    case "$KERN" in
        *icrosoft*WSL2 | *icrosoft*wsl2) IS_WSL2=true;;
        *icrosoft) error "Microsoft WSL1 is not currently supported. Please use WSL2 with 'wsl --set-version <distro> 2'" ;;
        *) ;;
    esac

    # Get latest release info including pre-releases
    if [ "$INCLUDE_PRE_RELEASE" = true ] && [ -z "${OLLAMA_VERSION:-}" ]; then
        LATEST_RELEASE=$(curl -s https://api.github.com/repos/ollama/ollama/releases | grep -m 1 '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
        if [ -n "$LATEST_RELEASE" ]; then
            OLLAMA_VERSION="${LATEST_RELEASE#v}"
            status "Using latest pre-release version: $OLLAMA_VERSION"
        fi
    fi

    VER_PARAM="${OLLAMA_VERSION:+?version=$OLLAMA_VERSION}"

    SUDO=
    if [ "$(id -u)" -ne 0 ]; then
        if ! available sudo; then
            error "This script requires superuser permissions. Please re-run as root."
        fi
        SUDO="sudo"
    fi

    NEEDS=$(require curl awk grep sed tee xargs)
    if [ -n "$NEEDS" ]; then
        status "ERROR: The following tools are required but missing:"
        for NEED in $NEEDS; do
            echo "  - $NEED"
        done
        exit 1
    fi

    for BINDIR in /usr/local/bin /usr/bin /bin; do
        echo $PATH | grep -q $BINDIR && break || continue
    done
    OLLAMA_INSTALL_DIR=$(dirname ${BINDIR})

    # Backup existing installation if it exists
    BACKUP_DIR=""
    if [ -d "$OLLAMA_INSTALL_DIR/lib/ollama" ] ; then
        BACKUP_DIR="${OLLAMA_INSTALL_DIR}/lib/ollama.backup.$$"
        status "Backing up existing installation to $BACKUP_DIR"
        $SUDO mv "$OLLAMA_INSTALL_DIR/lib/ollama" "$BACKUP_DIR"
    fi
    status "Installing ollama to $OLLAMA_INSTALL_DIR"
    $SUDO install -o0 -g0 -m755 -d $BINDIR
    $SUDO install -o0 -g0 -m755 -d "$OLLAMA_INSTALL_DIR/lib/ollama"
    status "Downloading Linux ${ARCH} bundle"
    curl --fail --show-error --location --progress-bar \
        "https://ollama.com/download/ollama-linux-${ARCH}.tgz${VER_PARAM}" | \
        $SUDO tar -xzf - -C "$OLLAMA_INSTALL_DIR"

    if [ "$OLLAMA_INSTALL_DIR/bin/ollama" != "$BINDIR/ollama" ] ; then
        status "Making ollama accessible in the PATH in $BINDIR"
        $SUDO ln -sf "$OLLAMA_INSTALL_DIR/ollama" "$BINDIR/ollama"
    fi

    # Clean up backup after successful installation
    if [ -n "$BACKUP_DIR" ] && [ -d "$BACKUP_DIR" ]; then
        status "Removing backup after successful installation"
        $SUDO rm -rf "$BACKUP_DIR"
    fi

    # Check for NVIDIA JetPack systems with additional downloads
    if [ -f /etc/nv_tegra_release ] ; then
        if grep R36 /etc/nv_tegra_release > /dev/null ; then
            status "Downloading JetPack 6 components"
            curl --fail --show-error --location --progress-bar \
                "https://ollama.com/download/ollama-linux-${ARCH}-jetpack6.tgz${VER_PARAM}" | \
                $SUDO tar -xzf - -C "$OLLAMA_INSTALL_DIR"
        elif grep R35 /etc/nv_tegra_release > /dev/null ; then
            status "Downloading JetPack 5 components"
            curl --fail --show-error --location --progress-bar \
                "https://ollama.com/download/ollama-linux-${ARCH}-jetpack5.tgz${VER_PARAM}" | \
                $SUDO tar -xzf - -C "$OLLAMA_INSTALL_DIR"
        else
            warning "Unsupported JetPack version detected.  GPU may not be supported"
        fi
    fi

    install_success() {
        status 'The Ollama API is now available at 127.0.0.1:11434.'
        status 'Install complete. Run "ollama" from the command line.'
    }
    trap install_success EXIT

    # Configure systemd service if available
    configure_systemd() {
        if ! id ollama >/dev/null 2>&1; then
            status "Creating ollama user..."
            $SUDO useradd -r -s /bin/false -U -m -d /usr/share/ollama ollama
        fi
        if getent group render >/dev/null 2>&1; then
            status "Adding ollama user to render group..."
            $SUDO usermod -a -G render ollama
        fi
        if getent group video >/dev/null 2>&1; then
            status "Adding ollama user to video group..."
            $SUDO usermod -a -G video ollama
        fi

        status "Adding current user to ollama group..."
        $SUDO usermod -a -G ollama $(whoami)

        status "Creating ollama systemd service..."
        cat <<EOF | $SUDO tee /etc/systemd/system/ollama.service >/dev/null
[Unit]
Description=Ollama Service
After=network-online.target

[Service]
ExecStart=$BINDIR/ollama serve
User=ollama
Group=ollama
Restart=always
RestartSec=3
Environment="PATH=$PATH"

[Install]
WantedBy=default.target
EOF
        SYSTEMCTL_RUNNING="$(systemctl is-system-running || true)"
        case $SYSTEMCTL_RUNNING in
            running|degraded)
                status "Enabling and starting ollama service..."
                $SUDO systemctl daemon-reload
                $SUDO systemctl enable ollama

                start_service() { $SUDO systemctl restart ollama; }
                trap start_service EXIT
                ;;
            *)
                warning "systemd is not running"
                if [ "$IS_WSL2" = true ]; then
                    warning "see https://learn.microsoft.com/en-us/windows/wsl/systemd#how-to-enable-systemd to enable it"
                fi
                ;;
        esac
    }

    if available systemctl; then
        configure_systemd
    fi

    # WSL2 only supports GPUs via nvidia passthrough
    if [ "$IS_WSL2" = true ]; then
        if available nvidia-smi && [ -n "$(nvidia-smi | grep -o "CUDA Version: [0-9]*\.[0-9]*")" ]; then
            status "Nvidia GPU detected."
        fi
        install_success
        exit 0
    fi

    # Don't attempt to install drivers on Jetson systems
    if [ -f /etc/nv_tegra_release ] ; then
        status "NVIDIA JetPack ready."
        install_success
        exit 0
    fi

    # Install GPU dependencies on Linux
    if ! available lspci && ! available lshw; then
        warning "Unable to detect NVIDIA/AMD GPU. Install lspci or lshw to automatically detect and install GPU dependencies."
        exit 0
    fi

    check_gpu() {
        case $1 in
            lspci)
                case $2 in
                    nvidia) available lspci && lspci -d '10de:' | grep -q 'NVIDIA' || return 1 ;;
                    amdgpu) available lspci && lspci -d '1002:' | grep -q 'AMD' || return 1 ;;
                esac ;;
            lshw)
                case $2 in
                    nvidia) available lshw && $SUDO lshw -c display -numeric -disable network | grep -q 'vendor: .* \[10DE\]' || return 1 ;;
                    amdgpu) available lshw && $SUDO lshw -c display -numeric -disable network | grep -q 'vendor: .* \[1002\]' || return 1 ;;
                esac ;;
            nvidia-smi) available nvidia-smi || return 1 ;;
        esac
    }

    if check_gpu nvidia-smi; then
        status "NVIDIA GPU installed."
        exit 0
    fi

    if ! check_gpu lspci nvidia && ! check_gpu lshw nvidia && ! check_gpu lspci amdgpu && ! check_gpu lshw amdgpu; then
        install_success
        warning "No NVIDIA/AMD GPU detected. Ollama will run in CPU-only mode."
        exit 0
    fi

    if check_gpu lspci amdgpu || check_gpu lshw amdgpu; then
        status "Downloading Linux ROCm ${ARCH} bundle"
        curl --fail --show-error --location --progress-bar \
            "https://ollama.com/download/ollama-linux-${ARCH}-rocm.tgz${VER_PARAM}" | \
            $SUDO tar -xzf - -C "$OLLAMA_INSTALL_DIR"

        install_success
        status "AMD GPU ready."
        exit 0
    fi

    # Simplified CUDA installation - just show status
    if check_gpu lspci nvidia || check_gpu lshw nvidia; then
        status "NVIDIA GPU detected. CUDA driver installation may be required."
        status "Please ensure NVIDIA drivers are properly installed for GPU acceleration."
        install_success
        exit 0
    fi

    status "NVIDIA GPU ready."
    install_success
fi