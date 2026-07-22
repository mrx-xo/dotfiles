# dotfiles

Personal rig config — macOS and Windows. The repo is the source of truth: live
configs are symlinks back into here, so editing either side is the same file
and git tracks everything.

## Machines

- **MrX** — primary MacBook Pro (this setup's home)
- **MrX2** — second MacBook Pro, near-identical setup; org/notes sync via Syncthing (`~/roaming`)
- **VENGEANCE** — Windows desktop, configured from `windows/`

## Layout

```
.dotfiles/
├── macos/        # everything Mac: emacs, yabai, skhd, sketchybar, scripts, launchd, …
├── windows/      # everything Windows: glazewm, kanata, autohotkey, terminal, …
├── shared/       # cross-platform bits (CLAUDE.md)
├── docs/         # local scratch: PRDs, research, setup guides (untracked)
└── ebak/         # old pre-Elpaca Emacs config (archive)
```

## macOS

The heart of it. `macos/bootstrap.sh` takes a fresh machine to fully set up:
Homebrew + Brewfile, Node via nvm, Claude Code, all symlinks, fonts, launchd
agents, and services.

```bash
git clone <this-repo> ~/.dotfiles
~/.dotfiles/macos/bootstrap.sh
```

Re-running is safe. It prints the manual follow-ups at the end (Accessibility
grants for yabai/skhd, SIP for yabai's scripting addition, first Emacs launch
for Elpaca to bootstrap packages, cron install).

### What's in there

- **Emacs** (`macos/emacs/`) — the main event. Literate config in `emacs.org`
  (auto-tangles to `init.el` on save), Elpaca package manager, evil-mode,
  agent-shell for AI agents living inside the editor. Runs as a daemon via
  launchd. ERT smoke tests in `tests/config-tests.el`.
- **Window management** — [yabai](https://github.com/koekeishiya/yabai) (BSP
  tiling) + [skhd](https://github.com/koekeishiya/skhd) (hotkeys) +
  [sketchybar](https://github.com/FelixKratz/SketchyBar) (status bar) +
  [borders](https://github.com/FelixKratz/JankyBorders) (window highlights).
- **Hammerspoon** (`macos/hammerspoon/`) — misc macOS automation glue.
- **Terminals** — Ghostty config, plus a Dracula Terminal.app profile.
- **Neovim** (`macos/nvim/`) — secondary editor config.
- **Scripts** (`macos/scripts/`) — Emacs daemon/sandbox/restart helpers,
  monitor-mode switching, VENGEANCE wake-on-LAN, finance sync, and the
  agent-inbox daemon.
- **launchd** (`macos/launchd/` + `macos/emacs/*.plist`) — templates rendered
  by bootstrap (launchd can't expand `~`, so `__HOME__` gets baked in at
  install time).

### agent-inbox (phone screenshots → Emacs)

Telegram bot → local daemon → `~/agent-inbox/` → armed agent-shell buffer.
Take a screenshot on the phone, send it to the bot, it lands as an image
attachment in the Emacs agent conversation you armed with `SPC c I`.
Design doc: `docs/phone-screenshot-ez-send.md`. Needs one-time secrets on a
new machine (bot token in Keychain, chat ID in `~/.config/agent-inbox/env`) —
see the comments in `bootstrap.sh`.

### Emacs sandbox

A full isolated copy of the config at `~/.emacs-sandbox` for testing changes
without touching the running daemon. Launch with `Cmd+Shift+S`, resync with
`macos/scripts/emacs-sandbox.sh --fresh`.

### Config tests

After touching `emacs.org`/`init.el`:

```bash
/opt/homebrew/opt/emacs-plus@30/bin/emacs --batch \
  -l ~/.emacs.d/init.el \
  -l ~/.emacs.d/tests/config-tests.el \
  -f ert-run-tests-batch-and-exit
```

## Windows

See [`windows/README.md`](windows/README.md) — symlink-based like the Mac
side, with its own `bootstrap.ps1`. GlazeWM + kanata + AutoHotkey +
Windows Terminal + PowerShell/Starship, plus a Windows Emacs config.

## Docs

`docs/` holds the longer-form stuff: PRDs for features in flight, research
notes, and setup guides (SSH between machines, remote agent access, task
system, etc.). Worth skimming before rebuilding or extending any of the
bigger subsystems. It's gitignored scratch space — local to each machine,
not part of the repo.
