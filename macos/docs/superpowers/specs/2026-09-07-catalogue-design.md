# Catalogue Design

Date: 2026-09-07
Status: Approved, not yet implemented

**Goal:** Let a chat be kept on purpose and found again later, from the Mac
and from the phone, without Emacs bookmarks. Two features share the name:
**pin**, a visual ordering hint that dies with the chat, and **catalogue**, a
durable "keep this one" mark with a note and tags, stored next to the chat's
existing label in agent-recall's sidecar metadata.

## Why not bookmarks

The vendored `agent-shell-bookmark` records a session in Emacs's
`bookmark-alist`. It burned twice: a jump that silently opened a fresh empty
shell when the stored session could not be resumed, and the bookmark store
losing entries. Catalogue keeps nothing in bookmark-alist, keys everything by
session ID in a store that reindexing never touches, and resumes through the
strict path syzygy already uses for the phone, which refuses agent-shell's
fresh-session fallback and reports the failure instead.

## Decisions

- **Catalogue is curate, not snapshot.** A catalogued chat is the existing
  transcript, flagged. No copy is made. Transcripts are append-only and
  already indexed, so "saved" means findable, not frozen.
- **Pin is ephemeral and per surface.** Mac pin is major-pane anchoring,
  unchanged: an in-memory buffer list, tab row sorts anchored left. Phone pin
  is a separate in-memory list in the daemon, Orrery sorts pinned to the top.
  Neither is persisted, neither is shared. The set you want steady on a 4K
  frame is not the set you want under your thumb. Persistence is what
  catalogue is for.
- **Pin and catalogue are independent.** A pinned chat is not saved, a saved
  chat is not pinned.
- **Catalogue lives in agent-recall.** It is the natural companion to search,
  and the sidecar is agent-recall's own. Users who never press the key see
  nothing. Only phone bridges, phone pins, and Mac keybindings are rig-side.
- **Entry carries flag, note, tags.** Not flag only: the note is *why you kept
  it*, which the transcript never says. Tags are a later-scale aid; the
  project name is already a free tag.

## Data model (agent-recall)

Three keys in the existing per-session metadata alist in
`agent-recall-metadata-file`, alongside `label`, `model`, `effort`:

- `catalogued`: ISO timestamp string. Present means saved. Sort order for
  free. Set on first save, left alone on edits.
- `note`: one string, optional.
- `tags`: list of lowercase strings, optional, stored without a leading `#`.

Writes go through `agent-recall-metadata-put` / `-merge`, inheriting atomic
writes and reindex safety. Uncatalogue removes `catalogued` only; note and
tags survive so a later re-save restores them.

API, package-side:

```elisp
;; ~/roaming/projects/agent-recall/agent-recall.el
(agent-recall-catalogue-put session-id :note "why" :tags '("syzygy" "resume"))
(agent-recall-catalogue-remove session-id)       ; drops `catalogued' only
(agent-recall-catalogue-get session-id)          ; alist or nil
(agent-recall-catalogue-entries &optional tag)   ; newest save first
(agent-recall-catalogue-tags)                    ; every tag in use, for completion
```

Pins never touch the store.

## Mac (agent-recall commands + rig keys)

Three commands:

- `agent-recall-catalogue`: save or edit. Resolves the session ID from a live
  agent-shell buffer, a transcript-mode buffer, or the highlighted browse
  candidate. Prompts note, then tags (`completing-read-multiple` over
  `agent-recall-catalogue-tags`). Both prefilled when editing, both may be
  empty.
- `agent-recall-uncatalogue`: removes the flag.
- `agent-recall-catalogue-browse`: picker over catalogued sessions, newest
  save first, same candidate machinery as browse so RET suspends into the
  transcript, `b` returns, `r` resumes. Prefix arg narrows to one tag. Line
  shape:

  ```
  Sep 05  dotfiles  syzygy resume-from-History   #syzygy #resume
          why: Go struct dropped `resumable`, fix at the end
  ```

Also: `agent-recall-browse` with a prefix arg narrows to catalogued sessions.
Transcript-mode binds `s` to `agent-recall-catalogue` (mode map plus
`evil-define-key*`, never per-buffer evil calls) and shows a `Catalogued`
header entry with the note when set.

Resume safety: catalogue resumes arm syzygy's strict-resume guard
(`syzygy-recall--arm-strict-resume`), so an unresumable transcript says so
rather than handing back a blank chat. That arming is the one rig-side hook.

Keys (verified free in the live session on 2026-09-07):

- `SPC c k`: catalogue this chat
- `SPC c K`: browse catalogue
- `SPC m a`: rebound from `mr-x/agent-shell-bookmark-jump` to the catalogue
  browser. The bookmark integration stays loaded, nothing points at it.

## Phone (acp-mobile + syzygy bridges)

- **Pin.** `Pin` in the chat context menu next to `Kill session`. Pinned chats
  sort to the top of the Orrery with a small row marker. State: one list of
  buffer names in the daemon (syzygy), so a reload sees the same pins and a
  killed chat drops out on its own.
- **Save.** `Catalogue` in the chat context menu, and a `catalogue` button in
  the History detail view next to `resume`. Both prompt note then tags with
  the `window.prompt` pattern the label uses; tags comma-separated, prompt
  text lists tags in use. Saved chats show `Catalogued` with the note; the
  button becomes `uncatalogue`.
- **Browse.** No new screen. History dock gets a `Catalogued` chip beside the
  search that narrows to saved chats, newest save first. Search understands
  `#tag`; `#` alone equals the chip. Rows show tag chips and the note under
  the preview.
- **Bridges.** `syzygy-recall-transcripts-json` gains `catalogued`, `note`,
  `tags`. New: `syzygy-recall-catalogue-json`, `syzygy-recall-uncatalogue-json`
  (session ID, note, tags JSON, all base64 in, base64 JSON out, nil for an
  unknown session) and `syzygy-orrery-pin-json`. Go endpoints `/api/catalogue`
  and `/api/pin` on the `callElisp` helper (acp-mobile `69a2cfa`): validate,
  call, reply. No generic eval.

## Testing

- **agent-recall** (ERT, temp metadata store as in `test/test-metadata.el`):
  put/get round-trip; uncatalogue keeps note and tags; re-save restores them;
  entries newest first; browse narrowing catalogued-only and exact tag;
  transcript-mode `s` and header entry.
- **syzygy-recall** (`lisp/syzygy/syzygy-recall-test.el`): base64 round-trips
  for the three bridges; unknown session returns nil; transcripts JSON carries
  the new fields.
- **acp-mobile** (Go, fake emacsclient): exact expression per endpoint, 404 on
  nil, note and tag limits rejected. `index_test.mjs`: `#tag` parsing, chip
  state.
- **config-tests**: the three leader keys resolve to the intended commands.
- **By hand**: pin, save, browse once on the phone.

## Rollout

Each step usable alone. Steps 1 to 3 give a working Mac catalogue before the
phone changes.

1. agent-recall: data, commands, browse narrowing, transcript-mode key. Commit
   on `dev`, merge `main`, live-load. About half a day.
2. Dotfiles: keys, strict-resume arming, `SPC m a` rebind. About an hour.
3. syzygy-recall bridges and tests. About an hour.
4. acp-mobile: endpoints, Orrery pin, History chip, tags, note, save from chat
   menu and History. Push `fork/syzygy`, pin sha in `build-acp-tools.sh`,
   build, restart launchd agent. About half a day.
5. Glossary lines for catalogue and pin, rig doc entry for the keys.

## Prerequisites already shipped (2026-09-06/07)

- agent-recall `dev` = `main` at `6765179`: sidecar metadata store public,
  persistent picker navigation, provider icons, transcript-mode evil keys on
  the mode map (fixes Enter bailing out of the picker), truename matching.
- Dotfiles `4a3c7d6`: `mr-x/escape-quit` leaves vertico-suspend parked pickers
  alone (fixes Escape yanking to another chat).
- acp-mobile `69a2cfa`: `callElisp` helper; label, push, kill migrated.

## Out of scope

- Snapshot copies of transcripts.
- Sharing pins between Mac and phone.
- Removing the vendored `agent-shell-bookmark` file.
- Migrating existing bookmarks into the catalogue.
