# Glossary

Known definitions for the rig, the software, and the words that show up in
chats, commits, and docs. One line each; follow the pointer for depth. Device
and persona names (GAIA, POLLUX, DAEMON, ...) are in `docs/naming.md`, which
stays the canon for the mythology scheme. New term? Add it here in the same
breath as the thing it names.

## Systems and surfaces

- **SYZYGY** ("SIZ-i-jee"): the cross-device conversation-continuity system.
  Handoff between Macs plus phone access to live agent-shell chats. Elisp in
  `macos/emacs/.emacs.d/lisp/syzygy/`, shell and Go glue in `macos/syzygy/`.
  Named for the celestial alignment; see `docs/naming.md`.
- **Orrery**: the home screen of acp-mobile. Every chat and its state in one
  view: sessions or projects, status dot, label, bell, time. Named after the
  mechanical model that shows every body in the system at once. Code:
  `#orrery`, `showOrrery`, `orreryIsVisible` in `~/src/acp-mobile/index.html`.
- **acp-mobile**: the phone web app for agent-shell chats, served from MrX over
  Tailscale (`https://mrx.tail9179e0.ts.net`, home-screen install). Source in
  `~/src/acp-mobile`, pinned by `macos/syzygy/build-acp-tools.sh`.
- **acp-multiplex**: the Go proxy between agent-shell and the agent process
  that lets more than one frontend (Emacs, phone) share one ACP session.
- **ACP**: Agent Client Protocol, the JSON-RPC the agents speak. Every agent in
  agent-shell (Claude, Codex, Gemini) is an ACP backend.
- **agent-shell**: the Emacs package that hosts agent conversations. One buffer
  per chat. Config tangles to `agent-shell-config.el`, not `init.el`.
- **agent-shell-attention**: the agent-shell add-on that tracks which chats
  need you (done, failed, permission) and drives the modeline count and macOS
  notifications.
- **major-pane**: the Emacs pane that routes every agent chat into one place
  with header-line tabs. Its tab label is the chat's display name everywhere
  (notifications, phone, pushes).
- **Agent Terminal**: the raw-process view of an agent session, distinct from
  the chat buffer. See `docs/agent-terminal.md`.
- **agent-inbox**: phone screenshot to armed agent-shell buffer, via Telegram
  or AirDrop. See `docs/phone-screenshot-ez-send.md`.
- **mdox**: the rig reference docs in org (`mr-x-rig-mdox.org`,
  `mr-x-inventory-mdox.org`), searched with `SPC ?`.
- **the rig**: MrX plus its Emacs, window manager, and phone surfaces. "On the
  rig" means at the Mac, as opposed to on the phone.

## Chat and session vocabulary

- **turn**: one prompt and the agent's full response to it. Rig-initiated when
  Emacs sent the prompt, phone-initiated when acp-mobile did. The multiplex
  ends a phone turn with a synthetic `turn_complete` so Emacs still hears it.
- **label**: the user-set name of a chat (orange in the Orrery and header). Set
  from the rig or by tapping the title on the phone. Mirrored to
  `~/.acp-mobile/labels.json`.
- **sidecar**: a small JSON file Emacs writes for acp-mobile to read, keyed by
  session id: `labels.json`, `status.json`, `push.json`. Emacs owns the truth;
  the phone only reads.
- **bell / phone push**: opt-in per-chat iOS push when the agent finishes,
  fails, or needs a permission answer. Filled orange bell when armed, outline
  when not. `SPC c N` on the rig, the bell on the phone. Web Push from
  acp-mobile, tap opens the app on that chat. Design:
  `macos/docs/superpowers/specs/2026-09-05-agent-shell-phone-push-design.md`.
- **Shadow**: the DiceBear "Shadows" character each chat gets in its macOS
  notification, derived from the session id so it stays stable.
- **handoff**: resuming a chat on the other Mac (`SPC c H`), or the doc that
  lets a new chat pick up where this one stopped
  (`macos/docs/superpowers/plans/*-handoff.md`).
- **resync / live mode**: `SPC c y` re-syncs phone turns into the Emacs buffer
  once; `SPC c Y` keeps them rendering as they arrive.
- **away mode**: `away on|off|dark`, the remote-access safety toggle for when
  you leave the desk. `dark` also runs the HA sleep-desk script.
- **pin**: a saved message inside a chat on the phone (long-press), listed per
  chat and globally from the Orrery.

## Process words

- **PRD / design spec**: the doc written before or with a build, following
  `docs/templates/prd.md`. Lives in `macos/docs/superpowers/specs/` for rig
  work, `docs/` for subsystem-level PRDs. Reference it in a chat with
  `@docs/templates/prd.md`.
- **plan**: the ordered build steps for a spec, in
  `macos/docs/superpowers/plans/`. A handoff doc is a plan written for a fresh
  chat.
- **ATLAS**: `~/ATLAS.md`, the index of where every canonical doc lives. Check
  before creating a doc, update after shipping one.
- **fleet**: every machine (MrX, MrX2, VENGEANCE, home-lab, RHEA, KRONOS, the
  phones, the e-readers). Facts per box in `~/fleet/machines/<id>.md`;
  identify a box with `whereami`.
- **cue prefixes**: the fixed response openers agent-shell styles: `Next:`,
  `Cause:` / `Fix:`, `Separately:`, `Step N of M done:`.
