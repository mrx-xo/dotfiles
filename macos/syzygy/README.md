# SYZYGY — cross-device conversation continuity

The shell/Go half of syzygy (see `~/docs/naming.md`): remote on-demand access to
Claude Code sessions on the M4 from the Air/phone over Tailscale
(acp-multiplex + acp-mobile), plus cross-machine session handoff
(`agent-session-handoff.sh`, resumed in Emacs with `SPC c H`) and the
phone-link helper (`acp-link-to-phone.sh`). The elisp half lives in
`shared/emacs/lisp/syzygy/`.
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

The SYZYGY Lisp tests run headless, without agent-shell, against a temporary
state directory (never the real `~/.acp-mobile`):

```bash
~/.dotfiles/shared/emacs/tests/run-syzygy-tests.sh
```

## Known limitations

- **R3.7 blind spot**: the agent-shell buffer does NOT render turns initiated
  from the web UI (shell-maker only displays its own turns). Session state is
  shared — the web UI shows everything from both sides; Emacs only shows its own.
- Remote **spawn/clone** use the structured `syzygy-launch.el` bridges;
  kill uses `meta-agent-shell-close-session` in emacs.org. The CLI
  `agent-shell-spawn` remains available separately. The chat menu's Clone item
  POSTs `{cloneOf: <buffer name>}` to `/api/spawn`; the rig copies that
  buffer's agent, model, permission mode and directory into a fresh session
  (no history, same as `SPC c n`), label suffixed ` 2`.
- Session lifetime is coupled to the Emacs daemon (accepted trade-off, R3.3).

## Windows (NEMESIS)

Both Go tools build for Windows from the same pinned commits
(`GOOS=windows GOARCH=amd64 go build`); the only platform code is the
process-liveness probe in `procalive_{unix,windows}.go`. Setup, paths,
the at-logon task and health checks for the Windows box live in
[`windows/README.md`](../../windows/README.md#syzygy-phone-access-acp-mobile-on-nemesis).
Scope there is view-and-reply on existing Claude chats; the SYZYGY Lisp
that drives presets, history and resume is not loaded by the Windows Emacs.

## Fleet (one phone app for every machine)

One acp-mobile binary plays either role. At start it reads the registry
(`~/fleet/syzygy.json`, overridable with `"registry"` in
`~/.acp-mobile/config.json`): present means **hub**, absent means **node**.
Its own id is the first line of `~/.config/machine-id` (else the first
label of its tailnet hostname), and must match an `id` in the registry.
POLLUX is the hub; CASTOR and NEMESIS are nodes and carry no registry.

- **Hub**: `/api/sessions` fans out to every registry peer (2 s budget,
  so the reply can take about 3 s), merges their sessions with a `machine`
  badge on each, and adds `machines[]` (`id`, `name`, `state` awake or
  asleep, `lastSeen`). A phone socket for a remote session
  (`/ws?machine=<id>&sock=<pid>`) is relayed whole-frame to the owning node.
- **Node**: serves only its own sessions; its own link URL keeps working on
  its own, and its `/api/sessions` has no `machines` key.

Registry shape: spec section 6.2 of
`docs/active/specs/2026-10-18-syzygy-fleet-design.md` and the fixture
`~/src/acp-mobile/testdata/syzygy.json` (keys `id, name, host, ip, os,
role, wake, gaps`). The real file lives only in the private fleet repo.
After editing it, reload without a restart:

```bash
launchctl kill HUP gui/$(id -u)/com.marcosandrade.acp-mobile
```

Check what the hub sees:

```bash
curl -s -X POST -b "authkey=$(cat ~/.acp-mobile/authkey)" http://127.0.0.1:8090/api/sessions \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["machine"]); [print(m) for m in d.get("machines", [])]'
```

### Peer auth

A hub-to-node call carries no authkey. The node admits it only when all
four hold: the caller is a tailnet address (100.64.0.0/10), it sends the
`X-Acp-Peer: 1` header, `tailscale whois` on the caller reports the same
Tailscale login as the node, and the caller's Tailscale node name is listed
in the node's `hubs` (see the next section). The login check alone is not
enough: the same login also owns devices on this tailnet that are not fleet
machines. A peer-eligible call that fails the login or `hubs` check gets
**403**; a call without the header falls through to the cookie check and
gets **401**. Browsers cannot send the header on a WebSocket upgrade, so the
phone still needs the authkey.

### Node prerequisite: `hubs` in `config.json`

Every node lists the hubs it trusts in `~/.acp-mobile/config.json`
(`%USERPROFILE%\.acp-mobile\config.json` on Windows):

```json
{"hubs": ["<hub MagicDNS name>"]}
```

The entry is the hub's full MagicDNS name (as `tailscale status --self
--json` prints it as `DNSName` on the hub), case-insensitive, trailing dot
optional. Missing or empty `hubs` makes the node refuse every hub call, so
the hub shows it `asleep`, and the node logs
`peer auth: no hubs configured, hub calls will be refused` at startup. A
correct config logs `peer auth: admitting hubs [<hub MagicDNS name>]`. The
hub itself needs no `hubs` entry; it is never called as a node today, and
logs the "no hubs configured" line harmlessly. Restart the node after
editing the file.

### Node prerequisite: `tailscale` on the job's own PATH

The node opens its tailnet-IP listener and learns its login only when the
`tailscale` CLI resolves on the PATH the process was started with (the
launchd plist's `PATH`, or the Windows task's environment). acp-mobile
resolves every command it runs, `tailscale` included, against that PATH;
`extraPath` in `~/.acp-mobile/config.json` is only added to the environment
those commands run in, so it reaches what they spawn in turn (grandchildren),
never the lookup of `tailscale` itself. That is why a Mac node needs the
wrapper below in a directory on the plist's PATH.

- Mac: put the Tailscale wrapper in a directory on the plist's PATH. The
  app's CLI must be invoked through a script, not a symlink:
  `printf '%s\n' '#!/bin/sh' '/Applications/Tailscale.app/Contents/MacOS/Tailscale "$@"' > ~/.local/bin/tailscale && chmod 755 ~/.local/bin/tailscale`
  (POLLUX has the same wrapper in `/usr/local/bin` from the app's CLI
  install). Keep `config.json` with
  `{"extraPath": ["<home>/.local/bin", "/opt/homebrew/bin", "/opt/homebrew/opt/emacs-plus@30/bin", "/usr/local/bin", "/usr/sbin", "/Applications/Tailscale.app/Contents/MacOS"], "hubs": ["<hub MagicDNS name>"]}`
  for the tools acp-mobile spawns and the hub it trusts.
- Windows: the Tailscale installer puts `C:\Program Files\Tailscale` on the
  machine PATH, which is what makes it resolve. The `extraPath` entry in
  `%USERPROFILE%\.acp-mobile\config.json` is optional; the file must carry
  `hubs`:
  `{"extraPath": ["C:\\Program Files\\Tailscale"], "hubs": ["<hub MagicDNS name>"]}`.

Proof it worked: `~/.acp-mobile/link` names the tailnet host (not
`127.0.0.1`) and the error log has an `also listening on <tailnet IP>:8090`
line.

### Bootstrap a Mac node (CASTOR)

Run on CASTOR, after the pin bump is pushed from POLLUX:

```bash
git -C ~/.dotfiles pull --ff-only
mkdir -p ~/.acp-mobile ~/.local/bin ~/Library/Logs/acp-mobile   # launchd cannot open logs in a missing dir
printf '%s\n' '#!/bin/sh' '/Applications/Tailscale.app/Contents/MacOS/Tailscale "$@"' > ~/.local/bin/tailscale
chmod 755 ~/.local/bin/tailscale
HUB='<hub MagicDNS name>'
printf '{"extraPath": ["%s/.local/bin", "/opt/homebrew/bin", "/opt/homebrew/opt/emacs-plus@30/bin", "/usr/local/bin", "/usr/sbin", "/Applications/Tailscale.app/Contents/MacOS"], "hubs": ["%s"]}\n' "$HOME" "$HUB" > ~/.acp-mobile/config.json
python3 -m json.tool ~/.acp-mobile/config.json
zsh -lc '~/.dotfiles/macos/syzygy/build-acp-tools.sh'
launchctl bootstrap gui/$(id -u) ~/.dotfiles/macos/syzygy/com.marcosandrade.acp-mobile.plist
launchctl print gui/$(id -u)/com.marcosandrade.acp-mobile | grep -E '^\s*(state|pid) '
sed 's/authkey=.*/authkey=REDACTED/' ~/.acp-mobile/link
```

Later updates are just `git pull` plus `build-acp-tools.sh`, which
kickstarts the loaded job. After changing the wrapper or `config.json`,
`launchctl kickstart -k gui/$(id -u)/com.marcosandrade.acp-mobile`.

NEMESIS redeploys as in
[`windows/README.md`](../../windows/README.md#syzygy-phone-access-acp-mobile-on-nemesis):
cross-compile, stop the task, `scp`, rerun the task script with `-Start`.

### What remote sessions can do in step 1

From the hub's phone app a remote session (a card with another machine's
badge) can be viewed and replied to, and carries its machine badge. Nothing
else yet: no kill, fork, clone, label, pin, push or model change, no delete
or peek on remote cards, and the in-chat actions that run Lisp are
disabled. Those actions would otherwise run on the hub's own Emacs, so the
hub answers their routes with **501** (`remote machine actions arrive in a
later step`) whenever the request names a machine other than itself.

### Troubleshooting: a peer shows `asleep`

`asleep` means the hub's fetch to that node failed. Check, in order:

1. The node process is up (`launchctl print ...` or the scheduled task state).
2. The node's log has the `also listening on` line. If not, `tailscale` is
   not on the node's PATH (see the prerequisite) and it only listens on
   127.0.0.1.
3. From the hub, `curl -s -o /dev/null -w '%{http_code}' -H 'X-Acp-Peer: 1' -X POST http://<node tailnet IP>:8090/api/sessions`:
   200 is healthy; 403 means the login matches but the hub is not listed
   in the node's `hubs` (check the node log for `admitting hubs`; a
   `no hubs configured` line means `hubs` is missing or empty), or the
   node's `tailscale whois` saw a different login (different Tailscale
   account, or whois failing on the node); 401
   means the header did not arrive; connection refused or a timeout is the
   listener or a firewall on the node (on Windows, check that inbound
   port 8090 is allowed on the Tailscale interface).
4. A changed tailnet IP needs no edit: on any fetch error the hub refreshes
   the peer's IP from `tailscale status` and uses it on the next fetch. Edit
   the registry (and SIGHUP) only for a new id, name or host.

Verified 2026-10-25 headless from POLLUX: `machines[]` reported all three
awake, CASTOR sessions merged with their badge, and `/ws` through the hub
returned each node's own frame (and `unknown machine` for a bad id).
CASTOR read `asleep` before its job was bootstrapped. With `hubs` set, the
peer-header call returned 200 from the hub and 403 between the two nodes
(same login, not a listed hub), and `/api/kill?machine=<node id>` on the hub
returned 501.

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
Legacy preset, default and clone requests use `syzygy-launch-legacy-json`
and the same confirmation path. Both launch bridges return the exact buffer
even when configuration fails. Clone opens that buffer on failure; while
discovery is pending, `Open clone` retries discovery without spawning again.

Startup, model, permissions and effort each have a separate 60-second budget.
Settings are applied in that order, with explicit success/failure callbacks,
and checked again together before sending. Refusals identify the failed
setting and preserve the adapter's error; daemon `*Messages*` also records
the failure and buffer name. A late success never sends a held prompt.

Claude presets and saved drafts/pins keep historical model IDs through an
explicit, Claude-only alias map. The saved Fable 5.1 IDs `claude-fable-5-1`
and `fable[1m]` also resolve to `fable` when the adapter advertises that short
ID as **Fable 5.1**; a different advertised version is not substituted.
`opus[1m]` remains compatible too. An adapter-added 1M suffix is accepted for a bare ID;
different model generations and permission modes are never treated as equal.
Warm catalogues do not invent unsupported preset choices. Sonnet's preset
and phone label both say 5.5.

If Start is disabled on the Prompt step, the inline explanation identifies
a missing project, loading catalogue, or unsupported agent/model/permissions/
effort selection. Tap the agent summary above it to repair stale settings;
the draft stays intact. Closing and reopening New chat refreshes the catalogue.

Verified 2026-10-01: all ten rig presets started empty real sessions and
confirmed their model, permissions and requested effort; historical Claude
aliases, default launch and clone launch were also exercised. No provider
prompts were submitted by these startup checks. Automated regressions cover
rejections, setting mismatches, per-stage timeouts and recovery.

The rig preset pickers (`SPC c C` for a new chat in a project, `SPC c p`
for the current chat) share their choices with the phone. Codex presets
include `a` for Astra 6, `c` for Sol 6.1, and `x` for Sol 6.1 Max, all in
Full mode. The Max preset uses max reasoning; Astra and regular Sol use
high reasoning. Sol 6.1 replaces older Sol versions on the existing keys, including
the `SPC c x` Sol shortcut. Applying a Codex preset requires a Codex chat.

Sol 6.1 access was verified with Codex CLI 0.159.2. Agent-shell's
`CODEX_PATH=/opt/homebrew/bin/codex` selects the globally installed CLI
instead of codex-acp's bundled copy. After a CLI upgrade, start a new chat
to use the new process and model catalogue; existing chats keep their
running processes. No Emacs daemon restart is needed.

OpenCode is available in the Agent picker and through the `Luna 6 · Build`
rig preset on `O`, replacing Luna 5.6. It launches `openai/gpt-6-luna` in `build` mode through
`acp-multiplex`, using the installer's absolute executable path. The preset
keeps OpenCode launchable before any chat has advertised choices; after an
OpenCode chat opens, the pickers also expose its advertised models, Build/Plan
modes, and effort choices. OpenCode uses its existing CLI authentication.

Validation: `go test ./...` and `node --test index_test.mjs` in
`~/src/acp-mobile`; focused ERT in `shared/emacs/lisp/syzygy/syzygy-launch-test.el`.
Set `SYZYGY_UI_SHOTS` to an existing directory when running
`go test -run TestNewChatVisualReview` to capture phone-sized review images.
