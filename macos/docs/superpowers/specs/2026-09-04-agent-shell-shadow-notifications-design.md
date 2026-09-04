# Agent Shell Shadow Notifications Design

Date: 2026-09-04
Status: Awaiting written-spec review

**Goal:** Give each ACP conversation a stable DiceBear Shadows character in its macOS notifications so simultaneous agent chats are visually distinguishable.

## Scope

- Show the character only as the macOS notification content image.
- Preserve the existing major-pane label as the notification title and preserve agent-shell-attention's focus suppression.
- Keep `agent-shell-attention` as the only notification owner; `agent-shell-macext` notifications stay disabled.
- Do not show or manage the character in agent-shell, major-pane, Syzygy, or acp-mobile.
- Do not add character selection, names, moods, animation, or lifecycle behavior.

## Identity and Persistence

The ACP session ID is the identity source. The implementation hashes it with SHA-256 and uses that digest as both the DiceBear seed and cache filename. The same resumed session therefore produces the same Shadow after buffer closure, Emacs restart, or cross-device resume, without storing a new identity record.

The raw ACP session ID is never written to the image cache or sent to DiceBear. If a notification somehow fires before a session ID exists, it is delivered without a character rather than assigning an unstable one.

`agent-recall-metadata` is deliberately not used in this version. Metadata becomes useful only if a future interface lets the user override or select a character; deterministic derivation already solves persistence today.

## Image Source and Cache

DiceBear's current HTTP API generates a deterministic PNG from:

```text
https://api.dicebear.com/10.x/shadows/png?seed=<sha256>&size=128
```

Images are cached under `~/.emacs.d/var/agent-shell-shadows/`. The cache is machine-local, outside Git, and persistent across Emacs restarts. A temporary file is atomically renamed only after `curl` exits successfully and produces a non-empty PNG. Concurrent requests for one session share one download.

The Shadows artwork is CC0. The cache also prevents repeated network traffic and keeps an already-assigned character stable if the hosted generator later changes.

## Notification Flow

`agent-shell-attention` continues calling `mr-x/agent-shell-notify` with the buffer, title, and body. The notifier keeps the existing major-pane title calculation, derives the session digest from that buffer, and then follows this flow:

```text
agent-shell-attention event
  -> major-pane label becomes the title
  -> ACP session ID becomes an opaque Shadow seed
  -> cached PNG exists: terminal-notifier sends one notification with -contentImage
  -> cache miss: async curl fetches it, then terminal-notifier sends one notification
  -> any unavailable dependency or failed fetch: send one plain notification
```

The first uncached notification may be delayed by the image fetch, bounded to three seconds. Emacs never blocks on network I/O. Later notifications for that session use the cached file immediately.

`terminal-notifier` is added to `macos/Brewfile` and invoked with separate process arguments, including `-sender org.gnu.Emacs`, `-title`, `-message`, and `-contentImage`. AppleScript remains the fallback because its `display notification` command cannot attach a content image.

## Failure Behavior

- Missing session ID: notify immediately without an image.
- Missing `terminal-notifier`: use the current AppleScript notification.
- Missing `curl`, timeout, HTTP error, empty response, or invalid cache entry: notify once without an image.
- Failed temporary downloads are removed; an existing valid cached image is never overwritten by a failed request.
- Notification and download processes never query on Emacs shutdown.

## Code Boundaries

- Create `macos/emacs/.emacs.d/lisp/agent-shell-notify.el` for identity derivation, caching, asynchronous download, and delivery.
- Create `macos/emacs/.emacs.d/tests/agent-shell-notify-test.el` for focused behavior tests.
- Modify `macos/emacs/.emacs.d/emacs.org` to load the module and assign its notifier; regenerate `agent-shell-config.el` canonically.
- Modify `macos/Brewfile` to install `terminal-notifier` on both Macs during bootstrap.
- Extend `config-tests.el` only with the integration assertions that the focused module test cannot cover.

## Verification

Focused ERT tests will prove deterministic identity, distinct session identities, cache hits, successful first-fetch delivery, and failure fallback without duplicate notifications. Process calls will be captured at the boundary; seed/path logic and state transitions will use the real implementation.

The full config suite must pass, including tangled-output synchronization. A live daemon check must show macext notifications disabled, and a real notification must show a Shadows image while retaining the current title and body. Emacs will be live-evaluated, not restarted.

## References

- [DiceBear HTTP API](https://www.dicebear.com/integrations/http-api/)
- [DiceBear Shadows style](https://www.dicebear.com/styles/shadows/)
- [DiceBear licenses](https://www.dicebear.com/licenses/)
- [terminal-notifier usage](https://github.com/julienXX/terminal-notifier/blob/master/README.markdown)
- [Homebrew terminal-notifier formula](https://formulae.brew.sh/formula/terminal-notifier)
