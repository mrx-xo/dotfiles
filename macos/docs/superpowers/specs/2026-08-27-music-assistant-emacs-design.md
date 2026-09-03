# Native Emacs Music Assistant Frontend Design

Date: 2026-08-27
Revalidated: 2026-09-02 against Music Assistant 2.9.13 / schema 31
Status: Approved for implementation planning

## Summary

Build a native Emacs dashboard that controls Music Assistant directly over
its WebSocket API. The dashboard borrows the compact, artwork-forward feel of
Ready Player without copying Ready Player's implementation or using its
playback process. Music Assistant remains the sole owner of library data,
players, queues, playback state, and audio routing, so Emacs, Home Assistant,
and the Music Assistant web application always see the same state.

Version 1 provides a now-playing screen, queue display, playback controls,
player selection, and track search-and-play. It remembers the last selected
player and falls back to the existing `MrX.local` Snapcast player.

## Context

The target system currently has:

- Emacs 30.2 with `websocket.el` available through Elpaca.
- Music Assistant at `http://192.168.1.143:8095`, server version 2.9.13,
  API schema 31.
- Home Assistant connected to Music Assistant.
- A persistent Snapclient on the Mac, exposed as the `MrX.local` player.
- Spotify configured as a Music Assistant provider.
- No Music Assistant filesystem provider for the Krypt library yet.

Krypt provider setup is a separate server configuration prerequisite. The
frontend must work with the providers currently visible to Music Assistant;
once Krypt is added there, the same search path will include those tracks
without an Emacs-side library scanner.

The dotfiles repository is literate: `emacs.org` is the source of truth and
tangles to `init.el`. New behavior must be live-evaluated into the running
daemon after automated verification.

## Goals

- Show connection state, selected player, artwork, track metadata, elapsed
  time, duration, volume, playback state, and the active queue.
- Control play/pause, previous, next, seek, volume, and queue-item playback.
- Search Music Assistant for tracks and start a chosen track by replacing the
  selected player's queue.
- Receive player and queue changes as WebSocket events rather than polling.
- Remember the last explicitly selected player across Emacs restarts.
- Fall back to `MrX.local` when the saved player is absent or unavailable.
- Keep the Emacs UI responsive during network, authentication, image, and
  server failures.
- Keep the long-lived token out of source files, logs, command messages shown
  to users, and Git history.
- Make protocol and rendering behavior testable without a live server.

## Non-goals for Version 1

- A full artist, album, playlist, or provider browser.
- Playlist creation or editing.
- Queue reordering, enqueue-next, or append workflows.
- Player grouping, synchronized multi-room management, or queue transfer.
- Music Assistant provider configuration, including installing Krypt's
  filesystem provider.
- Creating or rotating Music Assistant authentication tokens from Emacs.
- Offline playback or an empv fallback backend.
- Reusing Ready Player private functions, faces, buffer state, or process
  lifecycle.

## Architecture

### Components

`macos/emacs/.emacs.d/lisp/music-assistant-client.el` is the protocol and
state boundary. It owns one WebSocket connection, request correlation,
authentication, timeouts, reconnect scheduling, server/player/queue state,
and event dispatch. It has no UI dependencies beyond normal Emacs callback
facilities.

`macos/emacs/.emacs.d/lisp/music-assistant.el` is the user interface. It owns
the special-mode buffer, faces, keymap, rendering, minibuffer search flow,
artwork cache, elapsed-time display timer, and user-facing commands. It calls
the client only through public functions and receives state-change callbacks.

`macos/emacs/.emacs.d/tests/music-assistant-tests.el` exercises both layers.
Client tests inject a transport send function and feed representative Music
Assistant messages into the real parser. UI tests render real state into
temporary buffers and assert user-visible behavior.

`macos/emacs/.emacs.d/emacs.org` declares the `websocket` dependency,
autoloads the dashboard, adds the saved player variable to `savehist`, and
binds `SPC s m` to the dashboard. Tangled `init.el` changes are generated from
that source block and never edited independently.

### Dependency direction

```
music-assistant.el -> music-assistant-client.el -> websocket.el
        UI                    protocol              transport
```

Neither layer depends on Ready Player or empv. Music Assistant owns playback:

```
Emacs -> Music Assistant queue -> selected player
                              -> MrX.local by default
```

## Configuration and Authentication

The user-facing configuration contains:

- `music-assistant-server-url`, default
  `http://192.168.1.143:8095`.
- `music-assistant-default-player-name`, default `MrX.local`.
- `music-assistant-keychain-service`, default
  `music-assistant-token`.
- `music-assistant-request-timeout`, default 10 seconds.
- `music-assistant-artwork-size`, default 256 pixels (a size accepted by the
  schema-31 image proxy).

The client retrieves the token with `/usr/bin/security` using argument-vector
process invocation, not a shell command. The Keychain service is
`music-assistant-token`; the account is `emacs`. Retrieval output exists only
in a temporary buffer and is erased after trimming. The token is inserted
only into the `auth` WebSocket request. Debug logging redacts the complete
`args` object for `auth` and never prints the token.

Provision the item manually in Keychain Access with service
`music-assistant-token` and account `emacs`. Do not use the interactive
`security add-generic-password ... -w` prompt for current Music Assistant
JWTs: the macOS prompt truncates values longer than 128 bytes. A protected
temporary file may instead be imported through the native Security framework,
provided the token never appears in a shell argument or captured output and
the plaintext file is removed afterward.

When the Keychain item is absent, the dashboard opens in an authentication
required state, identifies the required Keychain service, and leaves `g`
available to retry. It does not fall back to `.authinfo.gpg`, because that
source currently fails to decrypt in the running Emacs daemon.

## WebSocket Protocol

The WebSocket URL is derived from the configured HTTP URL by changing
`http`/`https` to `ws`/`wss` and appending `/ws` exactly once. For the current
server it is `ws://192.168.1.143:8095/ws`.

Connection states are explicit:

```
disconnected -> connecting -> authenticating -> ready
                    |               |            |
                    +------------> error <-------+
                    |                            |
                    +-------> reconnecting <-----+
```

The server's first message is server information. The client records the base
URL, server version, schema version, and minimum supported schema. Schema 31
is the tested target. An incompatible minimum schema is a terminal error,
not a reconnect condition.

Each command has a unique string `message_id` and the wire shape:

```json
{
  "message_id": "emacs-17",
  "command": "players/all",
  "args": {}
}
```

Pending requests are stored by message ID with a callback, errback, and
10-second timer. A matching success result cancels the timer and invokes the
callback. Error results and timeouts remove the pending request and invoke
the errback exactly once. Closing the client cancels all request and
reconnect timers and resolves pending requests as disconnected.

For schema 31 the client authenticates immediately after server information:

```json
{
  "message_id": "emacs-1",
  "command": "auth",
  "args": {"token": "<redacted>"}
}
```

After authentication succeeds it requests `players/all` and
`player_queues/all`, selects a player, resolves its active queue, and requests
`player_queues/items` for that queue. Initial queries are asynchronous; the
buffer renders partial states instead of waiting synchronously.

The client reacts to these event types:

- `player_added`, `player_updated`, and `player_removed` update the player
  collection and re-run player fallback if necessary.
- `queue_added`, `queue_updated`, and `queue_time_updated` update queue and
  elapsed-time state.
- `queue_items_updated` refetches items for the selected active queue.

Events for other players and queues may update cached collections but do not
replace the user's selected player. Unknown event types are ignored and may
be recorded in the sanitized log.

Reconnect uses delays of 1, 2, 4, 8, 16, then 30 seconds, capped at 30
seconds. Only one reconnect timer may exist. Opening an existing dashboard
or pressing `g` cancels the delay and retries immediately. Invalid/missing
authentication and incompatible schemas do not create retry storms.

## Player and Queue Selection

`music-assistant-last-player-id` is persisted through `savehist` whenever the
user explicitly chooses a player with `P`.

After fetching players, selection follows this order:

1. The saved player ID, if present and available.
2. An available player whose display name exactly equals `MrX.local`.
3. The first available player in case-insensitive display-name order.
4. No selection, with a visible `No available players` state.

The selected player's active queue is obtained from its active source when
that source names a known queue; otherwise its player ID is used as the queue
ID. The dashboard never silently follows activity in another room.

## Search and Playback

Pressing `s` prompts for a non-empty query and sends:

```json
{
  "command": "music/search",
  "args": {
    "search_query": "bladee",
    "media_types": ["track"],
    "limit": 25,
    "library_only": false
  }
}
```

While the request is in flight the header shows `searching...`; Emacs remains
responsive. Search results are normalized into candidates labeled with track,
artist, album, and provider where present. Empty results produce a message
and do not change the queue.

Choosing a result sends its canonical URI to
`player_queues/play_media` with the selected active queue and queue option
`replace`:

```json
{
  "command": "player_queues/play_media",
  "args": {
    "queue_id": "<selected queue>",
    "media": "<track uri>",
    "option": "replace"
  }
}
```

The UI waits for queue events to show the authoritative result rather than
inventing an optimistic queue. Selecting a displayed queue item sends
`player_queues/play_index` with its queue item ID.

## User Interface

The command `music-assistant` opens or reuses `*Music Assistant*` in
`music-assistant-mode`, derived from `special-mode`. The initial Evil state is
motion. The buffer is read-only outside rendering and has no mode line; its
header line carries connection and player status.

The visual hierarchy is:

1. Connection state and selected player.
2. Centered artwork, with a text placeholder when unavailable.
3. Title, artist, and album/year metadata.
4. Elapsed/duration text and a fixed-width progress bar.
5. Previous, play/pause, next, seek, and volume hints.
6. Queue rows, with the playing item and keyboard selection visually distinct.
7. A compact key-hint footer.

The original design uses the current Emacs theme through inherited faces; it
does not copy Ready Player code or face definitions.

Key bindings are:

- `SPC`: play/pause the selected queue.
- `p` / `n`: previous / next.
- `h` / `l`: seek backward / forward 10 seconds.
- `-` / `+`: lower / raise player volume.
- `j` / `k`: move queue selection down / up.
- `RET`: play the selected queue item.
- `s`: search for a track and replace the queue with it.
- `P`: choose and remember a player.
- `g`: refresh or reconnect immediately.
- `?`: show key help.
- `q`: bury the dashboard and close its connection and timers.

Rendering preserves queue selection by queue item ID. When that item
disappears, selection moves to the current item, then the first queue item.
Rerendering never selects, deletes, or replaces another window, avoiding the
dead-window advice failure previously seen around Ready Player.

While the queue is playing, a one-second UI timer derives current elapsed
time from the latest server elapsed value and update timestamp. It only
rerenders the progress/metadata display and never sends playback state back
to the server. Queue time events reset its baseline.

## Artwork

The UI chooses a thumbnail from the queue item or its media item. On schema
31, an image with `proxy_id` resolves to:

```
<server base URL>/imageproxy/<proxy_id>?size=256
```

Artwork is fetched asynchronously with `url-retrieve`, converted with
`create-image`, and cached by final URL. The cache stores successful images
and a short-lived failure marker so repeated renders do not hammer a broken
URL. Callbacks verify both the dashboard buffer and the requested track are
still current before installing an image. Failures render `[no artwork]` and
do not affect playback controls.

## Error Handling and Logging

The dashboard renders all failure states rather than signaling from network
callbacks:

- Missing token: show Keychain setup instructions.
- Invalid token: show authentication failed and stop automatic retries.
- Offline server or dropped socket: keep the last valid state dimmed and show
  reconnect timing.
- Request timeout: show the command category and allow manual retry.
- Missing selected player: run the documented fallback order.
- Missing queue: retain player controls that are meaningful and explain that
  no active queue exists.
- Malformed JSON or message: ignore it, retain valid state, and add a
  sanitized log entry.
- Artwork failure: use the placeholder.

The optional `*Music Assistant Log*` buffer contains timestamps, connection
transitions, command names, message IDs, event names, and error details. It
never includes the token. The full `auth` arguments and raw authenticated
frame are always replaced with `<redacted>` before formatting.

## Cleanup

`q` and `kill-buffer-hook` share one idempotent cleanup function. It closes
the WebSocket intentionally, cancels reconnect/request/progress timers,
kills temporary HTTP response buffers, clears callbacks, and prevents close
callbacks from scheduling reconnection. Reopening the dashboard creates a
fresh client and fetches authoritative server state.

## Testing Strategy

Development follows red-green-refactor. Every production behavior begins
with an ERT test that fails for the expected missing behavior.

Client tests cover:

- HTTP-to-WebSocket URL conversion.
- Keychain result normalization without exposing token values.
- Unique message IDs and exact command payloads.
- Success, error, partial/malformed, and timeout request handling.
- Authentication state transitions and redaction.
- Initial player/queue fetch after authentication.
- Player fallback order and last-player persistence boundary.
- Player, queue, queue-time, and queue-items event handling.
- Single reconnect timer, capped backoff, manual retry, and cleanup.
- Search and play-media payloads for schema 31.

UI tests cover:

- Connecting, authentication-required, ready, reconnecting, and error screens.
- Track metadata, progress, volume, and queue rendering.
- Queue selection preservation and fallback.
- Player picker labels and selected-player handoff.
- Search candidate formatting, empty results, and selected-track playback.
- Artwork placeholder and stale-callback rejection.
- Keymap behavior and idempotent buffer cleanup.

Tests inject the external WebSocket/image boundaries only. Assertions target
real client state, serialized payloads, rendered text/properties, and cleanup
effects rather than asserting that mocks were called.

Verification consists of:

1. Run the dedicated Music Assistant ERT suite in batch mode.
2. Tangle `emacs.org` and verify `init.el` is synchronized.
3. Run the existing 105-test configuration suite. The clean feature baseline
   has two unrelated stale agent-shell keybinding assertions; the feature may
   add zero additional failures. The user's dirty main checkout already
   contains the corrected assertions.
4. Byte-compile the two new Lisp files with warnings treated as errors where
   practical.
5. Load the verified files into the running Emacs daemon with `emacsclient`.
6. Add the long-lived token to Keychain if it is not already present.
7. Open the dashboard against the live schema-31 server, select `MrX.local`,
   search for Bladee, play a result, confirm the queue and progress update via
   server events, and pause playback.

## Rollout and Compatibility

The implementation targets the currently running schema 31 server. Protocol
details are isolated in `music-assistant-client.el` so a future schema change
does not require UI rewrites. Server information is checked before commands
are issued, and incompatibility is displayed explicitly.

The feature is developed on `feature/music-assistant-emacs` in
`.worktrees/music-assistant-emacs`. The main checkout's unrelated uncommitted
changes are not copied, staged, or modified. Integration must preserve those
changes and resolve only the small `emacs.org`, generated `init.el`, and
configuration-test additions from this feature.
