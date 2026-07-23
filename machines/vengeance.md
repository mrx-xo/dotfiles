# VENGEANCE — Windows gaming desktop

> You are on (or SSHing into) **VENGEANCE**, the Windows 11 gaming PC.
> RTX 5080, LAN `192.168.1.156`. Configured from `windows/` in the dotfiles repo.

## Roles

- Gaming PC first; dev/utility box second
- **PRIMARY Ollama host for the fleet** (since 2026-07-22): `vengeance:11434`
  on the tailnet (`100.111.162.124`), 78–118 tok/s on the RTX 5080.
  Auto-starts at logon via scheduled task `OllamaServe`; if the box is up but
  Ollama isn't: `ssh vengeance` then `schtasks /run /tn OllamaServe`.
  Models: qwen3.5:9b (main, use `think:false` for tools), llama3.2:3b, llama3.1:8b.
  `OLLAMA_KEEP_ALIVE=-1`. Windows user is `mnand` (`C:\Users\mnand`).
- **Temporary Immich remote ML worker**: CUDA ML container on `:3003`, used by
  the homelab's Immich for GPU-heavy job backlogs (see
  `docs/immich-remote-ml-setup.md` in windows/docs)
- Wake-on-LAN target — woken from MrX via `vengeance-wake.sh`

## SSH quirks (READ BEFORE RUNNING COMMANDS)

SSH lands in **Git Bash**, not PowerShell. Hard-won lessons:

- **Path mangling**: Git Bash rewrites `/`-prefixed args into Windows paths.
  Prefix commands with `MSYS_NO_PATHCONV=1` when passing Windows-style flags.
- **PowerShell from SSH**: complex PS commands break in quoting hell — use
  `powershell -EncodedCommand <base64-UTF16LE>` for anything non-trivial.
- **Display/session APIs don't work over SSH** (no interactive session token):
  anything touching displays/audio/GUI must run via a **scheduled task**
  triggered from the SSH session, not directly.
- **Ping is firewalled** — a dead ping does NOT mean the machine is down.
  Check a TCP port instead.

## Environment

- Window manager: GlazeWM (alt-based binds, gruvbox); keyboard: kanata
  (home-row mods); AutoHotkey for global Emacs keys
- Emacs: lean package.el config (~500 lines), NOT the literate macOS setup
- Shell: PowerShell + Starship; Windows Terminal
- Syncthing syncs `~/shared` (wired by bootstrap.ps1; device pairing is manual)
- `~/.dotfiles` repo is cloned here; `bootstrap.ps1` symlinks configs

## Sync boundaries

- No `~/roaming` here (that's Mac↔Mac only); `~/shared` is the synced folder
- Claude/agent state is per-machine, as everywhere in the fleet
