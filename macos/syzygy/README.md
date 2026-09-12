# SYZYGY — cross-device conversation continuity

The shell/Go half of syzygy (see `~/docs/naming.md`): remote on-demand access to
Claude Code sessions on the M4 from the Air/phone over Tailscale
(acp-multiplex + acp-mobile), plus cross-machine session handoff
(`agent-session-handoff.sh`, resumed in Emacs with `SPC c H`) and the
phone-link helper (`acp-link-to-phone.sh`). The elisp half lives in
`macos/emacs/.emacs.d/lisp/syzygy/`.
Full design: `~/docs/prd-remote-agent-access.md` (private repo).

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

With the app open, pushes about other chats show as an in-app banner
(tap opens the chat) and the Apple banner is held back; it is sent late
only if you leave within 20s without opening that chat. Trace any push
problem with `grep -E "webpush|push-trace" ~/Library/Logs/acp-mobile/acp-mobile.err.log`.

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

## New Chat

The phone's New Chat screen has separate searchable project, agent, model,
permission, and effort pickers. Rig presets fill all settings; individual
changes mark the preset Modified, and reset restores its values. Custom
presets, project pins/recents, and the unfinished draft are stored on the
current device. The folder icon enters an explicit rig directory; search
text never becomes a path.

`syzygy-launch.el` supplies `POST /api/launch-options` from configured agents,
rig presets, and advertised live-session choices. The daemon retains the
last advertised catalogue for agents whose chats have closed; before any
chat has advertised choices, only its preset choices are available.
Explicit `POST /api/spawn` settings are validated against this catalogue.
Model, permissions, and effort must be confirmed before the optional first
message is submitted. The response identifies the exact created buffer.
Partial failures keep the buffer and unsent draft available for recovery.
The return-to-draft icon releases recovery if the created chat is gone.
Missing configured defaults require a choice; the first permission option
is never silently selected.
Legacy preset and clone requests continue through the existing bridge.

OpenCode is available in the Agent picker and through the `OpenCode Luna · Build`
rig preset. It launches `openai/gpt-5.6-luna` in `build` mode through
`acp-multiplex`, using the installer's absolute executable path. The preset
keeps OpenCode launchable before any chat has advertised choices; after an
OpenCode chat opens, the pickers also expose its advertised models, Build/Plan
modes, and effort choices. OpenCode uses its existing CLI authentication.

Validation: `go test ./...` and `node --test index_test.mjs` in
`~/src/acp-mobile`; focused ERT in `lisp/syzygy/syzygy-launch-test.el`.
Set `SYZYGY_UI_SHOTS` to an existing directory when running
`go test -run TestNewChatVisualReview` to capture phone-sized review images.
