# Handoff: acp-mobile Web Push (tap opens the home-screen app)

Date: 2026-09-05
Status: Shipped and confirmed on the phone 2026-09-05 (all six steps;
tap opens the home-screen app on the right chat). The design spec is the
canon now; this doc stays as the build log.
Predecessor: `macos/docs/superpowers/specs/2026-09-05-agent-shell-phone-push-design.md`
(read it first; everything below assumes it).

## Why

Phone push for agent-shell chats shipped today via the Home Assistant
companion app. It works: bell on the phone arms a chat, rig and phone stay in
sync, pushes arrive for rig-sent and phone-sent turns and for permission
prompts. One problem: tapping the push opens the acp-mobile URL in Safari or
HA's in-app browser, never in the home-screen web app. iOS cannot route a URL
from one app into another app's home-screen web app. No `data` field fixes it.

The fix is Web Push sent by acp-mobile itself. iOS supports Web Push for
home-screen web apps since 16.4 (DAEMON is on iOS 26.6.1). A push that comes
from the web app opens that web app on tap. HA leaves the loop.

## Current state (all committed, all live)

dotfiles, branch main:
- `b55079b` agent-shell-push.el: buffer-local `agent-shell-push-mode`, off by
  default, `SPC c N`. Pushes on done / failed / permission by advising
  `agent-shell-attention--handle-success`, `--handle-failure`,
  `--handle-event`.
- `0d87ea2` `agent-shell-push-set` (called by acp-mobile) + sidecar
  `~/.acp-mobile/push.json` of armed session ids.
- `7ddbc9a` phone-initiated turns: advice on `agent-shell--on-notification`
  catches acp-multiplex's synthetic `session/update turn_complete`, guarded
  by `agent-shell--active-requests-p`.
- `61184fa` pin + doc.
- Tests: `macos/emacs/.emacs.d/tests/agent-shell-push-test.el` (21 ERT) and
  `config-test-agent-shell-push-integration` in `config-tests.el`.

acp-mobile, `~/src/acp-mobile`, branch `syzygy`, HEAD `e2a6555`:
- `eb3d212` header bell + `POST /api/push {bufferName, enabled}` +
  `push.json` merged into `/api/sessions` as `push` bool.
- `e2a6555` filled bell on navigator cards when armed.
- Tests: `push_test.go`. Full suite `go test -count=1 .` takes ~30s and
  passes.
- Pinned in `macos/syzygy/build-acp-tools.sh` (`ACP_MOBILE_COMMIT`), with
  a `# + local <sha> (...)` comment line per commit. Keep that convention.

The HA path today, in `agent-shell-push.el`:
- `agent-shell-push--command` builds a curl argv:
  `POST $HA_URL/api/services/notify/mobile_app_daemon` with bearer token
  from `~/.config/gaia/ha-token.txt`, JSON `{title, message, data{url,
  group, tag}}`.
- `agent-shell-push-spawn-function` is the test seam (tests capture argv,
  no real process).

## Verified facts the new session can rely on

- `tailscale serve` is already configured on MrX (Tailscale 1.102.1):
  `https://mrx.tail9179e0.ts.net` (tailnet only) proxies to
  `http://127.0.0.1:8090`. Cert domain `mrx.tail9179e0.ts.net`. Check with
  `/Applications/Tailscale.app/Contents/MacOS/Tailscale serve status`.
  So the secure origin Web Push needs already exists. No infra work.
- acp-mobile's websocket handshake requires `Origin` host == request `Host`
  (`main.go` Handshake func). Through `tailscale serve` both are
  `mrx.tail9179e0.ts.net`, so https works today. Verify once by loading the
  https URL and entering a chat.
- acp-mobile writes `~/.acp-mobile/link` on startup as
  `http://<tailnet-hostname>:8090?authkey=...`. The phone-link helper is
  `macos/syzygy/acp-link-to-phone.sh`. Both need to hand out the https URL
  once Web Push lands, because the home-screen app must be installed from
  the https origin. The user must re-add the home-screen app once. Say so
  explicitly at the end.
- Auth: every API route needs the authkey (query param on first load, then
  cookie). Secret at `~/.acp-mobile/authkey` (0600). Emacs can read that
  file to call acp-mobile on localhost.
- `index.html` already has `apple-mobile-web-app-capable` and standalone
  polish. There is no manifest.json and no service worker yet. iOS Web Push
  requires: standalone (home-screen) install, a service worker, and
  `Notification.requestPermission()` inside a user gesture. The bell tap is
  that gesture.
- Test instance recipe: `go build -o /tmp/acp-mobile-test . &&
  /tmp/acp-mobile-test --test-mode 18091`. It discovers the real sockets
  (real sessions). Open with the authkey from its log. The chrome-devtools
  MCP can drive it at 390x844 for UI checks (this is how the bell was
  verified). Web Push itself cannot be verified there; final check is the
  phone.
- Ship recipe: commit on `syzygy` branch, `go build -o
  ~/.local/bin/acp-mobile .`, `launchctl kickstart -k
  gui/$(id -u)/com.marcosandrade.acp-mobile`, then health: `grep -q ts.net
  ~/.acp-mobile/link`, `curl -s -o /dev/null -w '%{http_code}'
  http://127.0.0.1:8090/` returns 401. Restarting acp-mobile drops the
  phone websocket for a second; Emacs sessions are untouched.
- Never restart the main Emacs daemon. Live-load with
  `emacsclient --eval '(load-file "...agent-shell-push.el")'`.

## Design (agreed)

1. **acp-mobile Go**
   - VAPID keypair generated once, stored at `~/.acp-mobile/vapid.json`
     (0600). Library: `github.com/SherClockHolmes/webpush-go`.
   - `GET /api/push-key` returns the public key (base64url) for
     `pushManager.subscribe`.
   - `POST /api/push-subscribe {subscription}` stores the PushSubscription
     JSON in `~/.acp-mobile/push-subscriptions.json` keyed by endpoint.
     `DELETE` or `{unsubscribe:true}` removes it.
   - `POST /api/notify {bufferName, title, message}` (authkey required,
     localhost caller = Emacs) fans out Web Push to every stored
     subscription with payload `{title, body, bufferName, tag}`. Drop
     subscriptions that return 404/410.
   - Serve `/sw.js` from the embedded FS with `Service-Worker-Allowed: /`
     and no-store cache headers. Serve a minimal `/manifest.webmanifest`
     (`display: standalone`, `start_url: /`) and link it from `index.html`;
     iOS needs the manifest for Web Push in standalone mode.
2. **Service worker (`sw.js`)**
   - `push` event: `showNotification(title, {body, tag, data:{bufferName}})`.
   - `notificationclick`: `clients.matchAll({type:'window',
     includeUncontrolled:true})`, focus the first client and
     `postMessage({type:'open-session', bufferName})`; if none,
     `clients.openWindow('/?session=<bufferName>')`.
   - No fetch handler, no caching. Do not turn this into an offline app.
3. **index.html**
   - On load: register `/sw.js`. Listen for `message` events of type
     `open-session` and call the existing `selectSession` on the matching
     entry from `lastSessions` (fetch sessions first if empty). Also honor
     `?session=` on first load the same way.
   - Bell tap: if `Notification.permission !== 'granted'`, call
     `Notification.requestPermission()` first, then
     `registration.pushManager.subscribe({userVisibleOnly:true,
     applicationServerKey})` and POST it to `/api/push-subscribe`. Then the
     existing `/api/push` toggle. If permission is denied, still toggle on
     the rig but show a one-line alert that this phone will not get pushes.
   - Keep the outline/filled bell styling and the card bell as they are.
4. **Emacs (`agent-shell-push.el`)**
   - Replace the HA curl with `POST http://127.0.0.1:8090/api/notify`,
     header `Cookie: authkey=<contents of ~/.acp-mobile/authkey>` (check
     how the server reads the key; query param also works), JSON
     `{bufferName, title, message}`. Port from a defcustom, default 8090.
   - Remove `agent-shell-push-ha-url`, `-token-file`, `-service`,
     `-link-file`. Keep `agent-shell-push-spawn-function` as the seam.
   - Update the ERT suite: payload tests now assert bufferName/title/
     message and the localhost URL; drop the HA token/link tests; add
     "missing authkey file sends nothing".
5. **Links**
   - acp-mobile: when `tailscale serve status` shows an https proxy to its
     port, write the https URL (no port) into `~/.acp-mobile/link` and log
     it. Otherwise keep the current http form.
   - `macos/syzygy/acp-link-to-phone.sh`: no change if it reads the link
     file; verify.
6. **Docs**
   - Update the design spec (predecessor doc): delivery section becomes Web
     Push, HA path noted as retired with the date and the reason.
   - `macos/syzygy/README.md`: mention https URL + re-add home-screen app.

## Order of work (TDD throughout, tests red before code)

1. Go: VAPID load/generate, subscription store, `/api/push-key`,
   `/api/push-subscribe`, `/api/notify` with a send seam so tests never hit
   the network. `go test -run Push`.
2. `sw.js` + manifest + routes. Load the test instance in Chrome, confirm
   `navigator.serviceWorker.controller` is non-null after reload and the
   push key endpoint answers.
3. index.html: registration, bell subscribe flow, `open-session` handling,
   `?session=` param. Chrome check: tap bell, subscription POST appears in
   network log (Chrome will subscribe against a fake FCM endpoint; that is
   fine for the UI path).
4. Emacs: swap the transport, tests green, live-load, replay
   `agent-shell-push--on-success` on an armed buffer and see acp-mobile log
   the fan-out.
5. Link file + helper + docs. Commit acp-mobile, bump pin, rebuild, restart.
   Commit dotfiles.
6. Phone: open `https://mrx.tail9179e0.ts.net?authkey=...`, add to home
   screen, open from home screen, tap a bell, allow notifications, send a
   message from the phone, wait for the push, tap it, confirm it lands in
   the app on that chat.

## Gotchas already known

- iOS only grants Web Push to the standalone install. Safari tab: no push.
- `Notification.requestPermission()` must run synchronously inside the tap
  handler's call chain; an `await fetch` before it breaks the gesture on
  iOS. Request permission first, then do network.
- Service worker scope: serve `sw.js` at `/`, not under `/fonts/`.
- Web Push payload must be under 4 KB. Titles are major-pane labels; fine.
- acp-mobile caches nothing for `/`; the sw must not add a fetch handler or
  the `version` reload dance in `index.html` stops working.
- Nothing in dotfiles may contain LAN IPs or usernames beyond what is
  already there (repo is public). The tailnet hostname is already in the
  README.
- Do not use subagents unless asked. Do not restart Emacs. No emojis.

## Prompt for the new chat

Build acp-mobile Web Push per
`~/.dotfiles/macos/docs/superpowers/plans/2026-09-05-acp-mobile-web-push-handoff.md`.
Read that doc and the design spec it links first, then start at step 1.
