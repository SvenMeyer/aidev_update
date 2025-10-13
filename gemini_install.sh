#!/bin/bash

# Shared helpers for installing the Gemini CLI.

retry_command() {
    local max_attempts=2
    local attempt=1

    while [ $attempt -le $max_attempts ]; do
        if "$@"; then
            return 0
        else
            echo "Attempt $attempt failed. Retrying..." >&2
            ((attempt++))
            sleep 2
        fi
    done

    echo "All attempts failed." >&2
    return 1
}

red="$( (/usr/bin/tput bold || :; /usr/bin/tput setaf 1 || :) 2>&-)"
plain="$( (/usr/bin/tput sgr0 || :) 2>&-)"

status() { echo ">>> $*" >&2; }
fail() { echo "${red}ERROR:${plain} $*" >&2; }

install_gemini_cli() {
    local target_version="$1"

    if [ -z "$target_version" ]; then
        fail "No version provided to install_gemini_cli"
        return 1
    fi

    local npm_prefix
    if ! npm_prefix=$(npm config get prefix); then
        fail "Unable to determine npm global prefix"
        return 1
    fi

    local install_dir="${npm_prefix}/lib/node_modules/@google/gemini-cli"
    local backup_dir=""

    if [ -d "$install_dir" ]; then
        backup_dir="${install_dir}.backup.$$"
        status "Backing up existing installation to $backup_dir"
        if ! mv "$install_dir" "$backup_dir"; then
            fail "Failed to back up existing installation"
            return 1
        fi
    fi

    status "Installing @google/gemini-cli@$target_version"
    if retry_command npm install -g "@google/gemini-cli@$target_version"; then
        status "@google/gemini-cli@$target_version installed successfully"
        if [ -n "$backup_dir" ] && [ -d "$backup_dir" ]; then
            status "Removing backup after successful installation"
            rm -rf "$backup_dir"
        fi
        return 0
    fi

    fail "npm install command failed"
    if [ -n "$backup_dir" ] && [ -d "$backup_dir" ]; then
        status "Restoring previous installation from backup"
        mv "$backup_dir" "$install_dir"
    fi
    return 1
}
