# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

Cross-platform dotfiles monorepo for macOS and Windows. Each OS has its own config set — this is **not a merged config**, it's two deliberately different setups under one roof.

- **macOS**: Full daily-driver Emacs IDE (elpaca, literate org), yabai, skhd, sketchybar, hammerspoon
- **Windows**: Lean Emacs rig (package.el, Lua + LSP for RE4R modding, agent-shell), glazewm, kanata, autohotkey

## Repository Structure

```
dotfiles/
├── shared/
│   └── CLAUDE.md             # This file (OS-agnostic agent guidance)
├── macos/
│   ├── bootstrap.sh          # Symlink setup for macOS
│   ├── .zshrc
│   ├── docs/                 # macOS-specific docs
│   ├── emacs/.emacs.d/       # Full Emacs config (~6240-line init.el, elpaca, literate org)
│   ├── yabai/                # Tiling window manager
│   ├── skhd/                 # Hotkey daemon
│   ├── sketchybar/           # Status bar
│   ├── hammerspoon/          # Window scripting
│   └── scripts/              # Helper scripts
├── windows/
│   ├── bootstrap.ps1         # Symlink setup for Windows
│   ├── docs/                 # Windows-specific docs
│   ├── emacs/.emacs.d/       # Lean Emacs config (~503-line init.el, package.el)
│   ├── glazewm/              # Tiling window manager
│   ├── kanata/               # Home row mods
│   ├── autohotkey/           # Global hotkeys
│   ├── powershell/           # Shell config + scripts
│   ├── windows-terminal/     # Terminal settings
│   └── scripts/              # Helper scripts
├── ebak/                     # Old straight.el config backup
└── .gitignore
```

## Common Commands

### Initial Setup

**macOS:**
```bash
./macos/bootstrap.sh
```

**Windows (run from windows/ dir):**
```powershell
cd windows; .\bootstrap.ps1
```

### macOS Emacs Configuration

#### Regenerate init.el from emacs.org
After modifying `emacs.org`, tangle to regenerate `init.el`:
- In Emacs: `M-x org-babel-tangle` or `C-c C-v t`
- From command line: `emacs --batch -l org -f org-babel-tangle macos/emacs/.emacs.d/emacs.org`

#### Live Eval Rule (IMPORTANT)
When editing `emacs.org`, ALWAYS run the changed elisp via emacsclient so it takes effect immediately:
```bash
emacsclient --eval "(elisp-expression-here)"
```

#### Sandbox Emacs (IMPORTANT)
A separate, isolated Emacs instance exists for testing changes safely without affecting the main Emacs daemon.

**Location**: `~/.emacs-sandbox` - a complete copy of the main `~/.emacs.d`

**Launch**:
- **Keybinding**: `Cmd + Shift + S` (via skhd)
- **Script**: `~/.dotfiles/macos/scripts/emacs-sandbox.sh`
- **Direct**: `/opt/homebrew/opt/emacs-plus@30/bin/emacs --init-directory ~/.emacs-sandbox`

**Resync sandbox with main config**:
```bash
~/.dotfiles/macos/scripts/emacs-sandbox.sh --fresh
```

#### Package Management (Elpaca)
```elisp
M-x elpaca-update-all   ;; Update all packages
M-x elpaca-rebuild       ;; Rebuild a package
M-x elpaca-log           ;; View package log
```

#### Config Tests (IMPORTANT)
An ERT smoke test suite lives at `macos/emacs/.emacs.d/tests/config-tests.el`. **After modifying `emacs.org` or `init.el`, always run the tests to verify nothing broke.**

```bash
/opt/homebrew/opt/emacs-plus@30/bin/emacs --batch -l ~/.emacs.d/init.el -l ~/.emacs.d/tests/config-tests.el -f ert-run-tests-batch-and-exit
```

### macOS Window Manager Services

#### Yabai
```bash
yabai --restart-service
yabai --reload-config
```

#### SKHD
```bash
skhd --restart-service
skhd --reload
```

#### Sketchybar
```bash
brew services restart sketchybar
sketchybar --reload
```

### Windows Emacs Configuration

Windows Emacs uses `package.el` with MELPA. Edit `windows/emacs/.emacs.d/init.el` directly (no literate org tangling).

### Windows Services

- **GlazeWM**: Tiling WM, config at `windows/glazewm/config.yaml`, launched via startup shortcut
- **kanata**: Home row mods, config at `windows/kanata/kanata.kbd`
- **AutoHotkey**: Global Emacs hotkeys, script at `windows/autohotkey/emacs.ahk`

## Architecture Details

### macOS Emacs
- **Package Manager**: Elpaca (migrated from straight.el)
- **Configuration Style**: Literate programming with Org mode
- **Key Features**: Evil, Projectile, Magit, Org-roam, Vertico/Consult, vterm

### Windows Emacs
- **Package Manager**: package.el + MELPA
- **Configuration Style**: Single init.el, no literate config
- **Key Features**: Evil, agent-shell, Lua/LSP (eglot), vertico/orderless/consult/corfu

### Equivalence Map

- Editor: `macos/emacs/` (full) ↔ `windows/emacs/` (lean)
- Shell: `macos/.zshrc` ↔ `windows/powershell/`
- Bootstrap: `macos/bootstrap.sh` ↔ `windows/bootstrap.ps1`
- Tiling WM: `macos/yabai/` ↔ `windows/glazewm/`
- Hotkeys: `macos/skhd/` ↔ `windows/autohotkey/`
- WM scripting: `macos/hammerspoon/` ↔ (in glazewm)
- Status bar: `macos/sketchybar/` ↔ —
- Kbd remap: — ↔ `windows/kanata/`
- Terminal: — ↔ `windows/windows-terminal/`

## macOS Integration Notes

- Requires SIP partially disabled for yabai scripting additions
- Font preference: Iosevka (Emacs) and Liga SFMono Nerd Font (Sketchybar)

## Windows Integration Notes

- Requires Developer Mode ON or elevated shell for symlinks
- Font preference: FiraCode Nerd Font Mono (Emacs) and Cascadia Code (terminal)
- Dependencies installed via scoop

## Task Master AI Instructions
**Import Task Master's development workflow commands and guidelines, treat as if import is in the main CLAUDE.md file.**
@./.taskmaster/CLAUDE.md
