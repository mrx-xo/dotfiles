# MrX2 — MacBook Air (M2, 16GB)

> You are on **MrX2**, the secondary/beater MacBook Air. macOS, M2, **16GB RAM**.
> Login user is `MrX2`. Verify anytime: `scutil --get ComputerName`.

## Roles

- **Secondary (portable) Ollama host** — ~15 tok/s, tailnet-only
  (`mrx2:11434` from other machines; localhost here). NOT auto-started:
  bring it up with `~/roaming/projects/home-lab/scripts/ollama-ctl.sh start`.
  The PRIMARY Ollama host is **VENGEANCE** (RTX 5080, 78–118 tok/s) since
  2026-07-22 — prefer it when it's awake.
- Local-model agent experiments run here (Goose + qwen3.5:9b via Ollama)
- Secondary dev machine with a near-identical dotfiles setup to MrX

## Hardware constraints (IMPORTANT)

- **16GB RAM ceiling**: qwen3.5:9b (5.6GB) + llama3.2:3b (2GB toolshim parser)
  fit together. llama3.1:8b (4.9GB) does NOT fit alongside qwen — it hangs
  forever waiting to load. Don't queue two big models.

## Sync boundaries

- `~/roaming` — Syncthing-synced with MrX
- `~/.claude` (sessions, memory) — **per-machine**. Anything Claude learned on
  MrX is not known here, and vice versa.
- `~/.dotfiles` — git clone of the same repo as MrX; pull before assuming parity

## Differences from MrX

- **No acp-multiplex built here** — agent-shell falls back to plain
  `claude-agent-acp` (the config guards on `executable-find`)
- No agent-inbox daemon, no DDC monitor control, no macro pad
- May lack the plain "Iosevka" font — Emacs font cond-chain falls back to
  Nerd Font builds

## Reaching other machines

- MrX: check `~/.ssh/config` on this machine for the alias/route back
- `ssh homelab` / `ssh vengeance` — same fleet, see their machines/*.md files
