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
- **Delivery: Home Assistant companion push.** `POST
  /api/services/notify/mobile_app_daemon` on `home.andrade-lab.com`, bearer
  token from `~/.config/gaia/ha-token.txt` (same pattern as `away-mode.sh
  dark`). Works off the tailnet because HA is reachable over the public
  hostname.
- **Tap opens acp-mobile.** `data.url` carries the link from
  `~/.acp-mobile/link` (tailnet URL with authkey). Opening it still needs
  Tailscale on the phone.
- **Grouping.** `data.group` is `agent-shell`; `data.tag` is the buffer name so
  a newer event for the same conversation replaces the older banner instead
  of stacking.
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
  -> token file readable?                      no: message, stop
  -> build JSON {title, message, data{url, group, tag}}
  -> async curl POST to HA notify service (fire and forget)
```

## Files

- `macos/emacs/.emacs.d/lisp/agent-shell-push.el`: minor mode, event
  filters, payload builder, curl spawn, advice on
  `agent-shell-attention--handle-success`, `--handle-failure`, and
  `--handle-event`.
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

## Not in scope

- Shadow image on the phone banner (needs a hosted PNG).
- Rate limiting. One push per event; revisit if long autonomous runs get
  noisy.
- Persisting the armed flag across buffer kills or machines.
- Telegram or the Claude Code push tool as alternate channels.
