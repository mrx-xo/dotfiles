# SYZYGY history readiness

Approved in the conversation: explicit replay boundaries and loading-aware jump
to bottom, for new sessions only. No compatibility fallback. Never restart Emacs.

## Contract

Secondary multiplex connections receive JSON-RPC notifications in this order:
`acp-multiplex/replay_start`, snapshot records,
`acp-multiplex/replay_complete`, queued live records, subsequent live records.
Boundaries are not cached and are not sent to the primary Emacs frontend.

The mobile bridge forwards this ordered stream directly. The browser buffers
history until the complete marker, renders the newest history window, waits for
its fonts and images and a completed layout, then permits jump-to-bottom.
Live updates after the marker continue normally, including while assets settle.
Initial loading snaps to the end; reconnecting while reading preserves position.
A delayed `Loading chat…` status appears after 300 ms. Disconnection and leaving
a chat invalidate pending readiness work. No elapsed-time completion fallback.

## Execution checklist

- [x] Protocol: add failing boundary/order tests, implement markers, run proxy suite.
- [x] Bridge: test slow and fragmented replay plus live ordering; remove idle-based
  buffering so disconnect cleanup runs from the start; run bridge tests.
- [x] UI: test delayed history, delayed image layout, empty replay, disconnect and
  stale completion; gate the scroll button; preserve user scroll intent.
- [x] Verify both Go suites, browser tests, Node tests and review the final diff.
- [x] Commit/push fork changes, update dotfiles pins, build/install both binaries,
  restart only acp-mobile and verify its running binary.

## Files

- `~/src/acp-multiplex/proxy.go`, `frontend.go`, protocol tests.
- `~/src/acp-mobile/main.go`, `index.html`, replay and browser tests,
  existing socket fixtures in `main_test.go`, `ui_test.go`, `index_test.mjs`.
- `macos/syzygy/build-acp-tools.sh` and this execution record.

## Validation

Run `go test ./...` in each source repository, `node --test index_test.mjs` in
acp-mobile, focused browser checks at phone size, `git diff --check`, and
`bash -n macos/syzygy/build-acp-tools.sh`. New protocol tests must fail before
implementation. Existing sessions are deliberately outside the new guarantee.

## Result

Shipped proxy `0173b23` and mobile `4686dea` on their fork `syzygy` branches.
Both Go suites passed; the proxy also passed `go test -race`. All 55 Node tests
passed. Phone-size visual checks confirmed the loading indicator, 14 px button
clearance and a jump leaving zero remaining scroll. Review has no outstanding
findings. Installed binaries match the checked builds, acp-mobile is running,
and a fresh isolated installed proxy emitted start/complete for empty history.
The main Emacs daemon and existing multiplex processes were not restarted.
