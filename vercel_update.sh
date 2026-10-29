#!/usr/bin/env bash
# Update the Vercel CLI via its own `vercel upgrade`; install it first from
# npm (Vercel's official channel) when npm has no global vercel yet.
# Only the npm install is used: a pacman/AUR vercel is not touched, because
# makepkg strips its native binary, which then crashes on start.
if pacman -Qq vercel >/dev/null 2>&1; then
    echo "⚠ A pacman/AUR vercel package is still installed — remove it with: sudo pacman -Rns vercel"
fi
if npm ls -g vercel --depth=0 >/dev/null 2>&1; then
    exec "$(npm prefix -g)/bin/vercel" upgrade
fi
echo "vercel not installed via npm — installing the latest version…"
exec npm install -g vercel@latest
