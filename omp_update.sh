#!/usr/bin/env bash
# Update oh-my-posh via its own CLI; install it first on a fresh machine.
if command -v omp >/dev/null 2>&1; then
    exec omp update
fi
echo "omp not found — installing the latest version…"
exec bash -c "$(curl -fsSL https://ohmyposh.dev/install.sh)"
