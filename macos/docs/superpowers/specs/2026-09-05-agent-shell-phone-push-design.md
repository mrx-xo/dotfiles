# Agent Shell Phone Push Design

Date: 2026-09-05
Status: Shipped with the implementation

**Goal:** Let an opted-in agent-shell conversation push an iOS notification to
DAEMON when the agent finishes a turn, fails, or needs a permission answer, so
a session can be watched from the phone without polling acp-mobile.

## Decisions

- **Opt-in per buffer, default off.** `agent-shell-push-mode` is a buffer-local
  minor mode. Nothing pushes unless the user arms that specific conversation.
  The flag dies with the buffer; a resumed session must be re-armed.
- **Any agent.** The hook sits on `agent-shell-attention`'s event handlers,
  which are ACP-generic. Claude, Codex, Gemini, and any other agent-shell
  backend report the same three events.
- **Three events only.** `done` (turn complete, any stop reason except
  `cancelled`), `failed` (request error), and `permission` (permission
  request). Streaming chunks, tool progress, and permission responses never
  reach the push path. A user-initiated cancel is not pushed because the user
  caused it.
- **No focus suppression.** `agent-shell-attention` skips the macOS
  notification when the buffer is visible. The push path ignores that check:
  an armed buffer is usually still visible on the Mac the user walked away
  from.
- **No away-mode gate.** Arming a buffer is the "I am remote" signal. Coupling
  to `away` would add a second switch to remember.
- **Delivery: Web Push sent by acp-mobile.** Emacs posts `{bufferName,
  title, message}` to `http://127.0.0.1:8090/api/notify` (cookie
  `authkey=` from `~/.acp-mobile/authkey`). acp-mobile fans out one Web Push
  per stored phone subscription, signed with a VAPID keypair it generated
  once into `~/.acp-mobile/vapid.json`. The phone subscribes from the bell
  tap: `Notification.requestPermission()` inside the gesture, then
  `pushManager.subscribe` against `/api/push-key`, posted to
  `/api/push-subscribe` and stored in `~/.acp-mobile/push-subscriptions.json`.
  Subscriptions the push service reports gone (404/410) are dropped.
- **Tap opens the home-screen app on that chat.** The service worker
  (`sw.js`, root scope, no fetch handler) shows the notification and on tap
  focuses an open client and posts `{type: "open-session", bufferName}`, or
  opens `/?session=<bufferName>` when none is open. `index.html` handles
  both by selecting that session. This is the reason for the switch: iOS
  cannot route a URL from another app into a home-screen web app, and a
  push from the web app itself can.
- **Tap target is durable, not just messaged (fix 2026-09-05, acp-mobile
  `cd7efe9`).** First on-device use landed on the navigator, not the chat:
  iOS freezes a backgrounded home-screen app and reloads it on focus, so
  the `open-session` message went to a page that no longer existed, and
  the cold-launch URL is not always honored either. `sw.js` now writes the
  tapped bufferName to the Cache API (`acp-pending` / `/pending-session`)
  before messaging or opening a window; `index.html` reads and clears it
  after the initial session load and on every pageshow / focus /
  visibilitychange. Covered by two headless-Chrome tests in
  `push_tap_ui_test.go` (load route and resume route).
- **Secure origin.** Web Push needs https and the home-screen install must
  come from the same origin. `tailscale serve` on MrX proxies
  `https://mrx.tail9179e0.ts.net` to port 8090; acp-mobile detects that via
  `tailscale serve status --json` and writes the https URL (no port) into
  `~/.acp-mobile/link`. Falls back to the http tailnet URL when no serve
  proxy exists. Still needs Tailscale on the phone.
- **Grouping.** The Web Push `tag` is the buffer name so a newer event for
  the same conversation replaces the older banner instead of stacking.
- **Retired: Home Assistant companion push (2026-09-05).** The first
  delivery path posted to HA's `notify.mobile_app_daemon` with `data.url`
  pointing at the acp-mobile link. It worked, but a tapped banner always
  opened Safari or HA's in-app browser, never the home-screen app. No
  `data` field can fix that on iOS, so it was replaced the same day.
- **Title.** The major-pane tab label, via `agent-shell-notify--title`, so the
  push says which agent and which session, matching the Mac notification.

## Flow

Two entry points, because a turn can be started from either side:

- **Rig-initiated turn.** Emacs sent the prompt, so agent-shell gets the
  response and agent-shell-attention fires `done` / `failed`. Advice on
  `--handle-success` and `--handle-failure` pushes.
- **Phone-initiated turn.** Emacs never sent the prompt, so there is no
  response and no attention event. acp-multiplex broadcasts a synthetic
  `session/update {sessionUpdate: "turn_complete", stopReason}` to every
  frontend except the sender. Advice on `agent-shell--on-notification`
  catches it, guarded by `agent-shell--active-requests-p` so an in-flight
  rig turn is never double-counted. This was the bug found on first use
  (2026-09-05 morning): pushes worked for rig turns and not for phone turns.
- **Permission requests** arrive as notifications on both paths and reach
  the attention `permission-request` event either way.

```text
agent-shell-attention event (done | failed | permission)
  or synthetic turn_complete notification (phone-initiated turn)
  -> agent-shell-push-mode on in that buffer?  no: stop
  -> stop reason is "cancelled"?               yes: stop
  -> ~/.acp-mobile/authkey readable?           no: message, stop
  -> build JSON {bufferName, title, message}
  -> async curl POST http://127.0.0.1:8090/api/notify (fire and forget)
  -> acp-mobile: Web Push {title, body, bufferName, tag} to every subscription
  -> sw.js showNotification; tap -> open-session message or /?session=
```

## Files

- `macos/emacs/.emacs.d/lisp/agent-shell-push.el`: minor mode, event
  filters, payload builder, curl spawn, advice on
  `agent-shell-attention--handle-success`, `--handle-failure`, and
  `--handle-event`. Port in `agent-shell-push-port` (8090), key file in
  `agent-shell-push-authkey-file`.
- acp-mobile (`~/src/acp-mobile`, branch `syzygy`): `webpush.go` (VAPID,
  subscription store, `/api/push-key`, `/api/push-subscribe`,
  `/api/notify`, `/sw.js`, `/manifest.webmanifest`, serve-URL detection),
  `sw.js`, `manifest.webmanifest`, bell subscribe flow and session routing
  in `index.html`; tests in `webpush_test.go`. Both `/sw.js` and the
  manifest are served without the authkey (iOS fetches the manifest without
  cookies; neither holds a secret). The page CSP gained `worker-src 'self'`.
- `macos/emacs/.emacs.d/tests/agent-shell-push-test.el`: ERT suite. External
  processes are captured at the command boundary; tests assert on the argv
  and JSON the module would hand to curl.
- `emacs.org` agent-shell section: `(require 'agent-shell-push)` next to the
  Shadow notifier, plus `SPC c N` bound to `agent-shell-push-mode`.

## Phone-side toggle (the bell)

The primary control surface is acp-mobile, not the rig. A bell sits right of
the chat title in the header: outline and muted when off, filled orange when
on (same orange as a labeled title). `SPC c N` on the rig flips the same
switch and the two stay in sync both ways.

```text
tap bell  -> POST /api/push {bufferName, enabled}
          -> emacsclient (agent-shell-push-set "<buffer>" t|nil)
          -> minor mode toggles; sidecar ~/.acp-mobile/push.json rewritten
          -> reply {ok, push} sets the final bell state
/api/sessions merges push.json as a `push` bool per session, so entering a
chat shows the rig's current state without an extra round trip.
```

- The sidecar is rewritten from live buffers on every toggle and on
  kill-buffer, so it never carries dead sessions. Unlike labels.json it is
  not merged, because armed state is not meant to persist.
- Same validation and escaping as `/api/label`: buffer name must match
  `validBufferName`, quotes and backslashes are escaped in the Lisp call.
- acp-mobile side lives in `~/src/acp-mobile` (commits `eb3d212` header
  bell, `e2a6555` card bell; pinned in `macos/syzygy/build-acp-tools.sh`);
  Go tests in `push_test.go`.
- Session cards in the navigator show a small filled orange bell after the
  name when armed, and nothing when off. State-only, not a tap target; the
  sessions poll (every 12s while the navigator is visible) keeps it fresh.

## Phone setup (once per phone)

Open the https link from `~/.acp-mobile/link` (or `acp-link-to-phone.sh`),
Add to Home Screen, open from the home screen, tap a bell, allow
notifications. A home-screen app added from the old `http://...:8090` URL
is a different origin and will never receive pushes; delete it and re-add.
Pushes only reach the home-screen install, never a Safari tab.

## Not in scope

- Shadow image on the phone banner (needs a hosted PNG).
- Rate limiting. One push per event; revisit if long autonomous runs get
  noisy.
- Persisting the armed flag across buffer kills or machines.
- Telegram or the Claude Code push tool as alternate channels.
