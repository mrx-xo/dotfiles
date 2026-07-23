# MrX — primary MacBook Pro

> You are on **MrX**, Marcos's main dev machine. macOS, Apple Silicon (M4).
> Hostname `MrX.local`. Verify anytime: `scutil --get ComputerName`.

## Roles

- Primary development machine — the big Emacs setup (daemon + agent-shell) lives here
- Runs the **agent-inbox daemon** (launchd `com.marx.agent-inbox`): Telegram bot,
  phone screenshots → `~/agent-inbox/` → armed agent-shell buffer
- Runs **acp-multiplex + acp-mobile** (remote agent access over Tailscale, web UI :8090)
- Controls the physical monitors via DDC (`monitor-mode.sh` — routes displays
  between MrX / VENGEANCE / work laptop; macro pad F17-F19)
- Can wake VENGEANCE via WoL (`vengeance-wake.sh`) and MrX2 via
  `mrx2-wake.sh` (add `relay` arg to send via homelab when off-LAN)

## Sync boundaries (IMPORTANT)

- `~/roaming` — Syncthing-synced with MrX2 (org files, notes, agenda, projects)
- `~/.claude` (sessions, memory) and `~/.emacs.d/var/` (shell-maker history) —
  **per-machine, NOT synced**. Claude memory on MrX2 is a different brain.
- `~/.dotfiles` — git repo, cloned on MrX, MrX2, and VENGEANCE. Source of truth
  for configs; live configs are symlinks into it.

## Reaching other machines

- `ssh mrx2` (alias `shm2`) — M2 Air, login user is `MrX2`
- `ssh homelab` (alias `shl`) — Ubuntu home server, user `home-lab`
- `ssh vengeance` (alias `shv`) — Windows gaming PC; see machines/vengeance.md
  for the Git Bash quirks BEFORE running commands there

## Gotchas

- Window manager stack: yabai + skhd + sketchybar (SIP partially disabled)
- Emacs: main daemon + a sandbox daemon (socket `sandbox`) for testing config
- The `emacs.org` literate config auto-tangles; agent-shell section tangles to
  `agent-shell-config.el`, NOT `init.el`
- No Ollama runs here — local-model requests go over the tailnet:
  **`vengeance:11434`** (RTX 5080, primary, needs the box awake) or
  `mrx2:11434` (Air, slow fallback, manual start)
