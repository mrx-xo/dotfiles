# Windows dotfiles

Personal Windows configs, managed as symlinks from this repo.

## What's here

| Path | Symlinks to |
|------|-------------|
| `emacs/.emacs.d/init.el` | `%APPDATA%\.emacs.d\init.el` |
| `emacs/.emacs.d/early-init.el` | `%APPDATA%\.emacs.d\early-init.el` |
| `windows-terminal/settings.json` | Windows Terminal `LocalState\settings.json` |
| `powershell/Microsoft.PowerShell_profile.ps1` | `Documents\WindowsPowerShell\…_profile.ps1` |
| `powershell/starship.toml` | `~/.config/starship.toml` |

The repo is the source of truth — edit files here (or in their live location, since
they're symlinked, it's the same file) and git tracks the changes.

## Setup on a new machine

1. Enable **Developer Mode** (Settings → Privacy & security → For developers),
   so symlinks can be created without admin. *(Or run the script as Administrator.)*
2. Clone this repo.
3. Run the bootstrap:
   ```powershell
   .\bootstrap.ps1
   ```
   It backs up any existing real config to `*.bak`, then replaces it with a symlink
   into this repo. Re-running is safe.

## PowerShell prompt (riced)

Gruvbox [Starship](https://starship.rs) prompt themed to match the rest of the setup
(gold `#fabd2f` accent, gold `◇` prompt char mirroring the Emacs agent-shell symbol).
Needs a Nerd Font for glyphs — Windows Terminal is set to `CaskaydiaCove NF`
(the family name the `CascadiaCode-NF` scoop package registers; *not* "...Nerd Font").

```powershell
scoop install starship CascadiaCode-NF
```

The profile also enables PSReadLine history autosuggestions (↑/↓ search, Tab
menu-complete) and a few aliases (`ll`, `g`, `gs`, `gl`, `which`, `..`, `dotfiles`).

## Window manager (GlazeWM)

[GlazeWM](https://github.com/glzr-io/glazewm) is the tiling WM — a Windows port of
the macOS yabai/skhd setup. Config lives in `glazewm/config.yaml` (gruvbox gold
borders, 10px gaps, `alt`-focus / `alt+shift`-move / `ctrl+alt`-resize, workspaces
`alt+1..5`). It has a built-in keybind engine, so there's no separate hotkey daemon.

```powershell
scoop install glazewm
```

> **Why not komorebi?** We started on komorebi + whkd, but komorebi's IPC is an
> AF_UNIX socket and on this machine (Win11 25H2) `komorebic`'s `connect()` fails
> with `os error 10022` (WSAEINVAL), killing every hotkey. It's a known class of
> Windows AF_UNIX breakage. GlazeWM's IPC is a localhost WebSocket/TCP server, which
> dodges it entirely.

Unlike the symlinked configs above, `config.yaml` is **not** symlinked into `~/.glzr`
(symlinks need admin here). `bootstrap.ps1` instead creates a login shortcut that runs
`glazewm start --config <repo file>`, so GlazeWM reads straight from the repo — no
admin, and it never goes stale when an editor rewrites the file on save.

## Home row mods (kanata)

[kanata](https://github.com/jtroo/kanata) turns the home row into modifiers — each key
is its letter when tapped, a modifier when held. Mirrors the programmable keyboard's
**CASG** layout (pinky → index):

| Keys | Hold = |
|------|--------|
| `a` `;` | Ctrl |
| `s` `l` | Alt |
| `d` `k` | Super (Windows key) |
| `f` `j` | Shift |

Config is `kanata/kanata.kbd` (adapted from kanata's `home-row-mod-advanced` sample —
bilateral combinations + no-mods-while-typing to avoid misfires). Super (`d`/`k`) is
GlazeWM's modifier, so you drive the WM from the home row.

```powershell
scoop install kanata vcredist2022
```

Wired like GlazeWM: not symlinked — `bootstrap.ps1` makes a login shortcut running
`kanata --cfg <repo file>`. Validate edits with `kanata --cfg kanata\kanata.kbd --check`.
Tune `tap-time` / `hold-time` in the config if you get misfires. (kanata only remaps
non-elevated windows unless it runs elevated.)

## Ollama background service

`scripts/ollama-serve.ps1` waits for this machine's Tailscale IPv4 address, then
starts Ollama tailnet-only with a 64,000-token default context and persistent model
residency. `scripts/setup-ollama-serve.ps1` installs it as the `OllamaServe` task with
startup and logon triggers, background login, and failure retries.

Deploy the serve script to the user profile, then run the setup script from
PowerShell. Re-running setup is safe.

```powershell
Copy-Item .\scripts\ollama-serve.ps1 "$HOME\ollama-serve.ps1" -Force
.\scripts\setup-ollama-serve.ps1
```

Verify with `schtasks /query /tn OllamaServe /v /fo list` and `ollama ps`.

## Notes

- On machines without Developer Mode / admin, `bootstrap.ps1`'s symlinks fail; the
  PowerShell profile + `starship.toml` can instead be **hardlinked** (no elevation,
  same live-edit behavior): `New-Item -ItemType HardLink`.
- Symlinks mean editing the config in Emacs/Terminal updates the repo directly — just
  `git add -p && git commit` to save changes.
- To migrate later (e.g. fold into a cross-platform dotfiles repo), this whole folder
  can move into a `windows/` subdirectory; only the paths in `bootstrap.ps1` would need
  adjusting.
