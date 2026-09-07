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
├── AGENTS.md     # canonical project instructions for coding agents
├── CLAUDE.md     # imports AGENTS.md for Claude Code
├── macos/        # everything Mac: emacs, yabai, skhd, sketchybar, scripts, launchd, …
├── windows/      # everything Windows: glazewm, kanata, autohotkey, terminal, …
├── shared/       # cross-platform scripts and configuration
├── docs/         # just the public PRD template (private docs live in ~/docs)
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
- **Karabiner** (`macos/karabiner/`) — caps lock to control (Karabiner
  overrides System Settings modifier keys once installed), plus DualShock 4
  buttons wired to Music Assistant and push-to-talk.
- **Terminals** — Ghostty config, plus a Dracula Terminal.app profile.
- **Neovim** (`macos/nvim/`) — secondary editor config.
- **Scripts** (`macos/scripts/`) — Emacs daemon/sandbox/restart helpers,
  monitor-mode switching, VENGEANCE wake-on-LAN, finance sync, and the
  agent-inbox daemon.
- **launchd** (`macos/launchd/` + `macos/emacs/*.plist`) — templates rendered
  by bootstrap (launchd can't expand `~`, so `__HOME__` gets baked in at
  install time).

### Agent skills (`~/skills`, private repo)

Personal agent skills live OUTSIDE this repo, in a private `skills` repo on
the home forge ([agentskills.io](https://agentskills.io) `SKILL.md` format —
one canonical copy, readable by any harness). Bootstrap clones it and
symlinks each skill into `~/.claude/skills/` and `~/.codex/skills/`; this
repo only does the wiring.

### Agent instructions

Project guidance has one canonical copy in `AGENTS.md`. Claude Code imports it
through the root `CLAUDE.md`; Codex reads `AGENTS.md` directly. Update
`AGENTS.md` rather than duplicating rules between harness-specific files.

Rules that apply to every project, not just this repo, are not here either —
they live in the private docs repo as `~/docs/agents/core.md` (every agent) and
`~/docs/agents/orchestrator.md` (session drivers and delegators). Every
installed CLI agent is pointed at them by
`macos/scripts/wire-agent-instructions.sh`, which `bootstrap.sh` runs.

### agent-inbox (phone screenshots → Emacs)

Telegram bot → local daemon → `~/agent-inbox/` → armed agent-shell buffer.
Take a screenshot on the phone, send it to the bot, it lands as an image
attachment in the Emacs agent conversation you armed with `SPC c I`.
Design doc: `~/docs/phone-screenshot-ez-send.md`. Needs one-time secrets on a
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

The longer-form stuff — PRDs for features in flight, research notes, and setup
guides (SSH between machines, remote agent access, task system) — lives in a
separate PRIVATE repo, `~/docs`, cloned by `bootstrap.sh` from the home forge.
It is private because most of those documents name machines, paths and LAN
details that must never appear in this repo, which is public. Worth skimming
before rebuilding or extending any of the bigger subsystems; the index to all of
it is `~/ATLAS.md`.

What stays here is `docs/templates/prd.md`, the design-spec template, since
`AGENTS.md` references it by repo-relative path.
