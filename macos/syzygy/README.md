# SYZYGY — cross-device conversation continuity

The shell/Go half of syzygy (see `docs/naming.md`): remote on-demand access to
Claude Code sessions on the M4 from the Air/phone over Tailscale
(acp-multiplex + acp-mobile), plus cross-machine session handoff
(`agent-session-handoff.sh`, resumed in Emacs with `SPC c H`) and the
phone-link helper (`acp-link-to-phone.sh`). The elisp half lives in
`macos/emacs/.emacs.d/lisp/syzygy/`.
Full design: [docs/prd-remote-agent-access.md](../../docs/prd-remote-agent-access.md).

## Architecture

```
Emacs daemon (always up)
  └── agent-shell = PRIMARY → spawns `acp-multiplex claude-agent-acp`
                                (socket: $TMPDIR/acp-multiplex/<pid>.sock)
acp-mobile (launchd, port 8090) = SECONDARY
  └── discovers sockets; serves web UI on 127.0.0.1 AND the tailnet IP
Air/phone → https://mrx.tail9179e0.ts.net?authkey=…  (tailscale serve → 8090)
```

`tailscale serve` proxies `https://mrx.tail9179e0.ts.net` to port 8090
(`/Applications/Tailscale.app/Contents/MacOS/Tailscale serve status`).
acp-mobile detects that and hands out the https URL in `~/.acp-mobile/link`.
The https origin matters: phone push is Web Push from the home-screen web
app, which needs a secure origin, a service worker, and an install from
that exact origin. If the phone's icon was added from the old
`http://...:8090` URL, delete it and re-add from the https link, then tap a
chat's bell and allow notifications. Design:
`macos/docs/superpowers/specs/2026-09-05-agent-shell-phone-push-design.md`.

## Files here

- `build-acp-tools.sh` — clone/pin/build both Go tools into `~/.local/bin`
- `com.marcosandrade.acp-mobile.plist` — launchd agent; install with:
  ```bash
  cp com.marcosandrade.acp-mobile.plist ~/Library/LaunchAgents/
  launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.marcosandrade.acp-mobile.plist
  ```
- `wake-m4.sh` — run from the Air: WoL via home server, then opens the UI

## Related config (not in this dir)

- **agent-shell primary**: `agent-shell-anthropic-claude-acp-command` is set to
  `("acp-multiplex" "claude-agent-acp")` in `macos/emacs/.emacs.d/emacs.org`
- **Adapter**: use `claude-agent-acp` (0.23.x, the renamed successor package),
  NOT the deprecated `claude-code-acp` (0.12.x). The old one lacks
  `session/list`, which agent-shell calls after every turn — result is an
  "Error handling request … Method not found" Notices block on every message.
  (The PRD's source analysis cites claude-code-acp; its conclusions carry over —
  0.23.x also makes no fs/terminal reverse calls.)
- **acp-mobile PATH**: `~/.acp-mobile/config.json` → `extraPath` (must include
  dirs holding `tailscale`, `claude-agent-acp`, `emacsclient`, `lsof`)
- **Secrets**: `~/.acp-mobile/authkey` (0600). The URL to open lives in
  `~/.acp-mobile/link`. Delete `authkey` + restart to rotate.
  `~/.acp-mobile/vapid.json` (0600) is the Web Push signing keypair and
  `push-subscriptions.json` the phone subscriptions; deleting `vapid.json`
  invalidates every phone subscription (re-tap a bell to resubscribe).

## Health checks

```bash
# link file must contain the tailnet hostname, NOT 127.0.0.1 (else the
# tailscale CLI wasn't found on PATH and remote access silently broke)
grep -q "ts.net" ~/.acp-mobile/link && echo OK || echo BROKEN
# https form means tailscale serve was detected (needed for phone push)
grep -q "^https://" ~/.acp-mobile/link && echo HTTPS || echo "http only: check tailscale serve"

launchctl list | grep acp-mobile          # running?
ls "$TMPDIR"acp-multiplex/*.sock          # sessions exposed?
tail ~/Library/Logs/acp-mobile/acp-mobile.err.log
```

## Known limitations

- **R3.7 blind spot**: the agent-shell buffer does NOT render turns initiated
  from the web UI (shell-maker only displays its own turns). Session state is
  shared — the web UI shows everything from both sides; Emacs only shows its own.
- Remote **spawn/kill/clone** from the phone go through `agent-shell-spawn`
  (`macos/scripts/`, symlinked into `~/.local/bin`) and
  `meta-agent-shell-close-session` in emacs.org. The chat menu's Clone item
  POSTs `{cloneOf: <buffer name>}` to `/api/spawn`; the rig copies that
  buffer's agent, model, permission mode and directory into a fresh session
  (no history, same as `SPC c n`), label suffixed ` 2`.
- Session lifetime is coupled to the Emacs daemon (accepted trade-off, R3.3).

## Wake-on-LAN facts (this M4)

- `pmset -g | grep womp` → already `1`
- Waking interface: **en8** (USB wired LAN), MAC `98:fc:84:e9:ab:e7`
- Home server must have `wakeonlan` installed and be SSH-reachable over
  Tailscale as `homeserver`
