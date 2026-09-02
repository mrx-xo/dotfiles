# Embedded Music Assistant Frontend in Emacs Design

Date: 2026-08-27
Revised: 2026-09-02
Status: Approved for implementation planning

## Summary

Version 1 embeds Music Assistant's official, server-hosted frontend in an
Emacs xwidget WebKit buffer. Emacs provides a reliable command and leader
binding that create or return to one tracked Music Assistant browser session.
The official frontend continues to own authentication, library browsing,
search, player selection, queue management, artwork, playback controls, and
live updates.

This replaces the earlier plan for a native Emacs dashboard backed by a
hand-written WebSocket client. Music Assistant still exposes an official
WebSocket and HTTP API, but Version 1 does not reimplement its client
semantics in Emacs. It also does not introduce a Python sidecar or route
control through Home Assistant.

The result is the complete Music Assistant interface inside Emacs with a
small maintenance surface. A native, Ready Player-style interface remains a
possible later version if using the embedded frontend reveals a concrete need
for one.

## Context

The target system currently has:

- Emacs 30.2 built with xwidget WebKit support.
- Existing xwidget browsing commands and Evil integration in emacs.org.
- A configured xwidget cookie file in the current Emacs setup.
- Music Assistant at http://192.168.1.143:8095, server version 2.9.13,
  API schema 31.
- The official Music Assistant frontend served successfully from that URL.
- Home Assistant connected to Music Assistant.
- A persistent Snapclient on the Mac, exposed as the MrX.local player.
- Spotify configured as a Music Assistant provider.
- No Music Assistant filesystem provider for the Krypt library yet.

Krypt provider setup is a separate server configuration prerequisite. Once
Krypt is added to Music Assistant, its contents appear in the same official
frontend without any Emacs-side library scanner or configuration change.

The dotfiles repository is literate: emacs.org is the source of truth and
tangles to init.el. Configuration changes must be tested, tangled, and then
live-evaluated into the running daemon.

## Decision

Version 1 uses the official frontend because:

- The frontend and server are developed and released together.
- It already implements the complete library, search, queue, player, and
  authentication flows.
- It automatically follows Music Assistant protocol and schema changes.
- It avoids duplicating authentication, request correlation, event handling,
  reconnect behavior, artwork fetching, and state reconciliation in Elisp.
- It keeps Music Assistant as the single source of truth seen by Emacs, Home
  Assistant, and other Music Assistant clients.
- The current Emacs build already provides the required embedded browser.

The official Music Assistant desktop application follows the same broad
model: it wraps the server-hosted frontend in a native webview and adds only
platform integration around it.

The alternatives remain:

1. A native Elisp WebSocket client would provide the most Emacs-specific
   interface and keybindings, but would create an unofficial client that must
   track upstream protocol behavior.
2. A native Emacs UI backed by Music Assistant's official Python client would
   avoid most protocol duplication, but would add a managed Python process
   and a second local IPC protocol.
3. Home Assistant control from Emacs could provide simple service buttons,
   but would not replace Music Assistant's library, search, and queue
   interface.

Those alternatives are deferred until actual xwidget use demonstrates a
problem they would solve.

## Goals

- Open the official Music Assistant frontend inside the current graphical
  Emacs frame.
- Bind SPC s m to a single user-facing Music Assistant command.
- Create a new xwidget session without commandeering an existing browsing
  session.
- Reuse the tracked Music Assistant session across repeated command
  invocations.
- Preserve the current in-app route while the session remains on the
  configured Music Assistant origin.
- Return the tracked session to the configured server URL if another browser
  command has navigated it away from Music Assistant.
- Recreate the session cleanly after its buffer is killed.
- Leave all playback, queue, search, artwork, player, and authentication state
  authoritative in the official frontend and Music Assistant server.
- Fail clearly when invoked from an Emacs build or frame that cannot display
  xwidgets.
- Keep Music Assistant credentials and tokens out of Emacs Lisp, command
  arguments, logs, and Git history.
- Make the small Emacs-owned lifecycle wrapper testable without contacting a
  live Music Assistant server.

## Non-goals for Version 1

- A native special-mode dashboard or a clone of Ready Player's presentation.
- Direct use of Music Assistant's WebSocket or HTTP APIs from Elisp.
- A Python client process or Emacs-to-Python IPC layer.
- Music Assistant control through Home Assistant entities or services.
- Emacs-owned player selection or automatic fallback to MrX.local.
- Custom playback, search, queue, volume, seek, or artwork commands.
- DOM scraping, JavaScript injection, or modification of the official
  frontend.
- Guaranteeing upstream frontend behavior with ERT tests.
- Supporting terminal Emacs or Emacs builds without xwidget WebKit.
- Remote-access, TLS, reverse-proxy, or VPN configuration.
- Music Assistant provider configuration, including adding Krypt.
- Offline playback or an empv fallback backend.

## Architecture

### Components

macos/emacs/.emacs.d/emacs.org contains the complete integration in the
existing xwidget/web-browsing section:

- music-assistant-server-url is the configurable frontend URL and defaults to
  http://192.168.1.143:8095.
- A private variable holds the tracked Music Assistant buffer object.
- The interactive music-assistant command creates, validates, restores, or
  displays that session.
- A buffer-local kill hook clears the tracked reference only when the tracked
  buffer itself dies.
- SPC s m invokes music-assistant.

macos/emacs/.emacs.d/init.el contains the generated form of the same
configuration. It is never edited independently.

macos/emacs/.emacs.d/tests/config-tests.el exercises the Emacs-owned session
lifecycle and leader binding. There is no dedicated Music Assistant test file
because Version 1 has no protocol or rendering subsystem.

Version 1 adds no package dependency. xwidget-webkit is part of the current
Emacs build. In particular, websocket.el is not needed by this feature.

### Dependency direction

    Emacs command
        -> built-in xwidget WebKit
            -> official Music Assistant frontend
                -> Music Assistant's own API and state
                    -> selected Music Assistant player

Emacs knows only the configured URL and the browser buffer. It does not parse
Music Assistant responses, inspect application state, or decide what player
or queue should be active.

### Ownership boundary

Emacs owns:

- Invocation through M-x and SPC s m.
- Creation and reuse of the xwidget session.
- Detecting a dead or invalid tracked buffer.
- Restoring the configured URL after the tracked webview leaves the Music
  Assistant origin.
- Clearing its buffer reference on buffer death.

The official frontend owns:

- Login and token handling.
- Connection and reconnection to Music Assistant.
- Server and schema compatibility.
- Provider and library browsing.
- Search and result presentation.
- Player selection.
- Now-playing state, queue state, artwork, and elapsed time.
- Playback, seek, volume, and queue commands.
- Error messages originating from Music Assistant.

Home Assistant and Emacs remain peers consuming the same Music Assistant
state. Neither proxies the other in Version 1.

## Session Lifecycle

The music-assistant command behaves as follows:

1. Verify that xwidget WebKit support is available in the current graphical
   Emacs.
2. If the tracked buffer is live, is in xwidget-webkit-mode, and still
   contains a WebKit session, display it.
3. Before displaying a reusable session, compare its current URI with the
   configured Music Assistant origin. Preserve any path, query, or fragment
   on the same origin so album, artist, queue, and settings views survive
   buffer switches.
4. If the session has navigated to another origin, navigate that same session
   back to music-assistant-server-url.
5. If the tracked buffer is absent, dead, or no longer a valid xwidget
   session, create a new session by calling the public
   xwidget-webkit-browse-url entry point with NEW-SESSION non-nil. Record the
   resulting buffer and attach the local cleanup hook.

Creating a new session explicitly prevents Music Assistant from initially
replacing an unrelated xwidget page. xwidget WebKit still behaves like a
browser: a generic browse command invoked while the Music Assistant buffer is
current can navigate that session elsewhere. Invoking music-assistant again
detects that condition and returns it to the configured origin.

The integration tracks the buffer object rather than depending on a fixed
buffer name. The built-in xwidget callback may rename the buffer from the
loaded page title, so buffer names are presentation rather than identity.

The normal xwidget controls remain available. In particular, its reload
command refreshes the current page, and quitting or burying the window does
not require custom Music Assistant cleanup. Killing the buffer destroys that
webview; the next invocation creates a fresh one.

## Configuration and Authentication

The only Music Assistant-specific user option in Version 1 is:

- music-assistant-server-url, default http://192.168.1.143:8095.

The value is a frontend origin or URL, not a WebSocket endpoint. The command
normalizes a trailing slash only for same-origin comparison; it does not
rewrite the configured value into a protocol URL.

Authentication occurs entirely inside the official frontend. On first use,
the user completes any login presented by Music Assistant in the embedded
page. Emacs does not retrieve a Keychain item, construct an authentication
frame, or receive the long-lived token as Lisp data.

The integration does not add new credential persistence. Any session
persistence comes from Music Assistant's frontend and WebKit's existing
website-data behavior. If that state is unavailable after an Emacs restart,
the official login screen is the expected recovery path.

The current URL uses unencrypted HTTP on the trusted home LAN. Making Music
Assistant available away from home must be designed separately with an
authenticated HTTPS or VPN path; Version 1 must not expose port 8095 directly
to the public internet.

## Player, Search, Queue, and Playback Behavior

All music interaction happens in the official page:

- Select MrX.local or another player with Music Assistant's player picker.
- Browse providers and the library.
- Search for tracks, albums, artists, or playlists.
- Start, pause, seek, skip, and change volume with official controls.
- Inspect and edit the active queue using capabilities offered by the running
  frontend.

Emacs does not force MrX.local or persist a separate player choice. The
official frontend's current behavior is authoritative. This avoids two
clients maintaining competing notions of the selected player.

When Krypt is later added as a Music Assistant filesystem provider, it
appears through the same browse and search UI. No Emacs change is required.

## User Interface

M-x music-assistant and SPC s m open or return to the embedded frontend. The
page supplies the complete visual hierarchy, responsive layout, artwork,
navigation, and controls.

Version 1 does not overlay a custom header, mode line, footer, faces, or
music-specific keymap. The surrounding buffer remains
xwidget-webkit-mode and retains the existing xwidget and Evil behavior.
Text entry and navigation therefore follow the configured xwidget workflow,
while application buttons and fields are handled by WebKit.

This intentionally gives up the original Ready Player-inspired native
appearance in exchange for upstream completeness and compatibility. Whether
that trade is acceptable is a rollout question to answer through actual use,
not by prebuilding a second frontend.

## Error Handling

The Emacs wrapper handles only errors inside its boundary:

- No xwidget support: signal a concise user error that names the configured
  Music Assistant URL and explains that a graphical xwidget-enabled Emacs is
  required.
- Dead tracked buffer: clear the stale reference and create a new session.
- Tracked buffer is no longer an xwidget session: discard the reference and
  create a new session.
- Tracked session left the Music Assistant origin: navigate it back to the
  configured URL.
- Session creation failure: leave no stale tracked buffer reference and
  preserve the original error.

Server unavailability, authentication failure, provider failure, and
playback errors remain visible in the official frontend. Emacs does not add
retry timers, shadow state, or a second log. The user can use the built-in
xwidget reload command or kill and reopen the buffer.

## Testing Strategy

The wrapper is small, but its owned behavior is covered with ERT tests before
implementation:

- The default server URL is correct.
- A first invocation requests the configured URL in a new xwidget session.
- A second invocation reuses the live valid Music Assistant buffer.
- Same-origin application routes are preserved.
- An off-origin tracked session is returned to the configured URL.
- A killed or invalid tracked buffer is replaced.
- Killing an old buffer cannot clear a newer tracked session.
- Missing xwidget support produces the documented user error.
- SPC s m resolves to music-assistant.

Tests replace only the xwidget entry points and session accessors. They do not
contact Music Assistant, execute frontend JavaScript, or assert upstream UI
details.

Verification consists of:

1. Run the focused configuration ERT tests in batch mode.
2. Tangle emacs.org and verify init.el is synchronized.
3. Run the complete existing Emacs configuration suite with no new failures.
4. Load the verified definitions into the running Emacs daemon.
5. Invoke SPC s m and confirm the official frontend renders in the tracked
   xwidget buffer.
6. Authenticate through the page if prompted.
7. Select MrX.local, search for Bladee, start a track, pause it, and confirm
   Home Assistant observes the same player state.
8. Leave and reopen the buffer, reload it, and verify a killed session is
   recreated.

ERT proves only the Emacs-owned wrapper. The final live check validates the
integration with the current official frontend.

## Rollout and Compatibility

Version 1 targets the current macOS graphical Emacs 30.2 daemon and its
xwidget WebKit implementation. It is intentionally unsupported in terminal
frames and non-xwidget Emacs builds.

Because the frontend is served by the running Music Assistant server, server
updates deliver their matching UI instead of requiring an Elisp schema
update. The server deployment currently tracks a latest container tag;
pinning or validating server upgrades remains a home-lab operational concern,
but no custom Emacs protocol client must be updated alongside it.

Implementation remains on feature/music-assistant-emacs in
.worktrees/music-assistant-emacs. Before implementation, rebase the feature
branch onto the current main branch so the new emacs.org and generated
init.el changes are based on the latest configuration. Unrelated changes
outside the feature's configuration, generated output, and tests remain out
of scope.

## Possible Native Version 2

A native interface is reconsidered only after using Version 1 identifies
specific xwidget limitations, such as poor keyboard navigation, undesirable
focus behavior, or a need for commands callable without displaying the
frontend.

If that version is justified, the preferred starting architecture is:

    native Emacs UI
        -> small local IPC boundary
            -> official Python music-assistant-client
                -> Music Assistant

That choice would reuse Music Assistant's maintained protocol implementation.
A direct Elisp WebSocket client remains possible, but requires an explicit
decision to own compatibility, authentication, reconnect, event, and request
semantics that Version 1 deliberately avoids.
