#!/bin/bash
set -e

DOTDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # …/dotfiles/macos

# ── Helpers ──────────────────────────────────────────────
step() { echo ""; echo "==> $1"; }

# ── 1. Homebrew ──────────────────────────────────────────
if ! command -v brew &>/dev/null; then
    step "Installing Homebrew..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    eval "$(/opt/homebrew/bin/brew shellenv)"
else
    step "Homebrew already installed"
fi

# ── 2. Brew Bundle ───────────────────────────────────────
# Newer Homebrew refuses to load formulae from third-party taps until
# they're explicitly trusted, so trust the ones our Brewfile uses first.
step "Trusting third-party taps..."
for tap in d12frosted/emacs-plus felixkratz/formulae koekeishiya/formulae \
           shaunsingh/sfmono-nerd-font-ligaturized oven-sh/bun; do
    brew tap "$tap" 2>/dev/null || true
    brew trust "$tap" 2>/dev/null || true
done

step "Installing packages from Brewfile..."
brew bundle --file="$DOTDIR/Brewfile"

# ── 3. Node (via nvm) ────────────────────────────────────
# The Brewfile installs the nvm formula, but nvm is only a version
# manager — it ships no node. Lay down a default LTS so node/npm work
# out of the box (per-project versions still switch via .nvmrc).
step "Installing Node LTS via nvm..."
export NVM_DIR="$HOME/.nvm"
mkdir -p "$NVM_DIR"
if [ -s "$(brew --prefix nvm)/nvm.sh" ]; then
    source "$(brew --prefix nvm)/nvm.sh"
    nvm install --lts || echo "nvm install failed, skipping (install node manually later)"
    # Global CLI tools Emacs expects on PATH (Tailwind LSP, and the ACP bridge
    # agent-shell uses to talk to Claude). Installed under the current node
    # version; re-run after an `nvm install` of a newer node.
    if command -v npm &>/dev/null; then
        for pkg in @tailwindcss/language-server @agentclientprotocol/claude-agent-acp; do
            npm i -g "$pkg" || echo "npm i -g $pkg failed, skipping"
        done
    fi
else
    echo "nvm.sh not found, skipping node install"
fi

# ── 4. Claude Code ───────────────────────────────────────
# Not a brew package — ships as a standalone installer that bundles its
# own runtime, so it doesn't depend on node and survives nvm switching.
step "Installing Claude Code..."
if ! command -v claude &>/dev/null; then
    curl -fsSL https://claude.ai/install.sh | bash || echo "Claude Code install failed, skipping"
else
    echo "Claude Code already installed"
fi

# ── 5. Symlinks ──────────────────────────────────────────
step "Creating symlinks..."

mkdir -p "$HOME/.config"
mkdir -p "$HOME/.hammerspoon"
mkdir -p "$HOME/Library/LaunchAgents"

# Canonical repo location: skhdrc/yabairc/plists all reference ~/.dotfiles.
# If the repo lives elsewhere (e.g. ~/dotfiles), symlink it so those paths
# resolve. If it already IS ~/.dotfiles, leave it alone (don't self-nest).
REPO_ROOT="$(cd "$DOTDIR/.." && pwd)"
if [ "$REPO_ROOT" != "$HOME/.dotfiles" ]; then
    ln -sfn "$REPO_ROOT" "$HOME/.dotfiles"
    echo "Linked ~/.dotfiles -> $REPO_ROOT"
fi

ln -sf "$DOTDIR/.zshrc" "$HOME/.zshrc"
ln -sf "$DOTDIR/.zshenv" "$HOME/.zshenv"
ln -sf "$DOTDIR/yabai/yabairc" "$HOME/.yabairc"
ln -sf "$DOTDIR/skhd/skhdrc" "$HOME/.skhdrc"
ln -sf "$DOTDIR/sketchybar" "$HOME/.config/sketchybar"
ln -sf "$DOTDIR/borders" "$HOME/.config/borders"
ln -sfn "$DOTDIR/ghostty" "$HOME/.config/ghostty"
ln -sfn "$DOTDIR/nvim" "$HOME/.config/nvim"
ln -sf "$DOTDIR/hammerspoon/init.lua" "$HOME/.hammerspoon/init.lua"

# whereami — fleet-wide machine identity helper (shared/, not macos/)
mkdir -p "$HOME/.local/bin"
ln -sf "$REPO_ROOT/shared/bin/whereami" "$HOME/.local/bin/whereami"

# ── Machine identity ─────────────────────────────────────
# ~/.config/machine-id is the fleet-wide source of truth for "which machine
# am I on" — read by ~/.zshenv (exports MACHINE_ID), `whereami`, and any
# agent that lands here over SSH. Facts files live in machines/<id>.md.
if [ ! -f "$HOME/.config/machine-id" ]; then
    DEFAULT_ID="$(scutil --get ComputerName 2>/dev/null | tr '[:upper:]' '[:lower:]' | tr -d ' ')"
    read -r -p "Machine id for this box [${DEFAULT_ID}]: " MACHINE_ID_INPUT
    echo "${MACHINE_ID_INPUT:-$DEFAULT_ID}" > "$HOME/.config/machine-id"
    echo "Wrote ~/.config/machine-id: $(cat "$HOME/.config/machine-id")"
fi

# Emacs LaunchAgents — generated from templates, not symlinked: launchd can't
# expand ~ or env vars in ProgramArguments, so bake this machine's $HOME into
# the __HOME__ placeholder at install time.
for pl in com.marcosandrade.emacsdaemon.plist com.marcosandrade.emacsclient.plist; do
    # rm the target first: if it's a stale symlink into the repo, `>` would
    # follow it and truncate the template itself (input == output). Deleting
    # the link ensures we always write a fresh regular file.
    rm -f "$HOME/Library/LaunchAgents/$pl"
    sed "s|__HOME__|$HOME|g" "$DOTDIR/emacs/$pl" > "$HOME/Library/LaunchAgents/$pl"
done

# agent-inbox daemon (phone screenshots → agent-shell; docs/phone-screenshot-ez-send.md).
# Needs one-time secrets on a new machine: bot token in the Keychain
# (security add-generic-password -s agent-inbox-token -w) and
# TELEGRAM_ALLOWED_CHAT_ID in ~/.config/agent-inbox/env.
mkdir -p "$HOME/Library/Logs/agent-inbox"
rm -f "$HOME/Library/LaunchAgents/com.marx.agent-inbox.plist"
sed "s|__HOME__|$HOME|g" "$DOTDIR/launchd/com.marx.agent-inbox.plist" \
    > "$HOME/Library/LaunchAgents/com.marx.agent-inbox.plist"

# ── 6. Emacs ─────────────────────────────────────────────
step "Setting up Emacs..."
if [ ! -d "$HOME/.emacs.d" ]; then
    ln -sf "$DOTDIR/emacs/.emacs.d" "$HOME/.emacs.d"
    echo "Linked ~/.emacs.d"
else
    echo "~/.emacs.d already exists, skipping (check it points to dotfiles)"
fi

# ── 6b. Fonts ────────────────────────────────────────────
# sketchybar's title item renders app icons from sketchybar-app-font.
# The nerd font (glyphs for date/battery/weather/etc.) comes via the
# Brewfile tap, but this one isn't on Homebrew — fetch it directly.
step "Installing sketchybar-app-font..."
APP_FONT="$HOME/Library/Fonts/sketchybar-app-font.ttf"
if [ -f "$APP_FONT" ]; then
    echo "sketchybar-app-font already installed"
else
    if curl -fL --retry 3 -o "$APP_FONT" \
        "https://github.com/kvndrsslr/sketchybar-app-font/releases/latest/download/sketchybar-app-font.ttf"; then
        echo "Installed sketchybar-app-font"
    else
        echo "Failed to fetch sketchybar-app-font (app icons will be blank); install it manually later"
    fi
fi

# ── 6c. Terminal.app Dracula profile ────────────────────
step "Importing Terminal.app Dracula profile..."
if [ -f "$DOTDIR/Dracula.terminal" ]; then
    open "$DOTDIR/Dracula.terminal"
    sleep 1
    defaults write com.apple.Terminal "Default Window Settings" -string "Dracula"
    defaults write com.apple.Terminal "Startup Window Settings" -string "Dracula"
else
    echo "Dracula.terminal not present, skipping"
fi

# ── 7. Services ──────────────────────────────────────────
step "Starting services..."

if command -v sketchybar &>/dev/null; then
    brew services start sketchybar 2>/dev/null || true
    echo "sketchybar started"
fi

if command -v borders &>/dev/null; then
    brew services start borders 2>/dev/null || true
    echo "borders started"
fi

if command -v syncthing &>/dev/null; then
    brew services start syncthing 2>/dev/null || true
    echo "syncthing started"
fi

# yabai/skhd don't ship brew-services plists — they install their own
# LaunchAgents via `--start-service`. Basic tiling works immediately; the
# scripting addition (needs SIP partially disabled) unlocks the extras,
# and both need Accessibility permission granted on first launch (a system
# prompt appears) — see Next steps below.
if command -v skhd &>/dev/null; then
    skhd --start-service 2>/dev/null || true
    echo "skhd started"
fi

if command -v yabai &>/dev/null; then
    yabai --start-service 2>/dev/null || true
    echo "yabai started"
fi

# ── 8. Emacs daemon ──────────────────────────────────────
step "Loading Emacs LaunchAgents..."
launchctl load "$HOME/Library/LaunchAgents/com.marcosandrade.emacsdaemon.plist" 2>/dev/null || true
launchctl load "$HOME/Library/LaunchAgents/com.marcosandrade.emacsclient.plist" 2>/dev/null || true

# ── Done ─────────────────────────────────────────────────
step "Done!"
echo ""
echo "Next steps:"
echo "  - Launch Emacs once to let Elpaca bootstrap all packages"
echo "  - Grant Accessibility to yabai AND skhd (System Settings > Privacy &"
echo "    Security > Accessibility), then: yabai --restart-service; skhd --restart-service"
echo "    They abort on launch until this is granted."
echo "  - For yabai's scripting addition (extra features): partially disable SIP,"
echo "    then run: sudo yabai --install-sa && sudo yabai --load-sa"
echo "  - Review commented-out items in Brewfile for extras you might want"
echo "  - Install cron jobs: crontab $DOTDIR/crontab"
