# Live Keymap Widget

## Metadata [REQUIRED]

- **Version**: 1.2 (adds optional per-keypress flash, previously a non-goal)
- **Created**: 2026-07-22
- **Status**: SHIPPED & VERIFIED — Phase A live 2026-07-24, Phase B live
  2026-07-27, stress test passed 2026-07-28 (layer tracking, tri-layer,
  mod-tap burst, held-mod highlight). Nothing open.
- **Priority**: P1 (should ship)


## Problem Statement [REQUIRED]

The keymap visualizer (`index.html`) shows the hotdox76v2 and Creator Micro
layouts, but only as a static page opened manually in a browser. Layers and
modifier legends are explored by clicking tabs and hovering — the page has no
awareness of what is actually happening on the keyboard. There is no
always-available, glanceable view of "what do my keys do *right now*" while
working in other apps.


## Goal [REQUIRED]

A lightweight, always-on desktop widget (Hammerspoon webviews rendering the
existing visualizer) showing BOTH boards stacked on the portrait side
monitor (Dell S2725HS, Display 3), sitting on the wallpaper layer and
updating live: held OS modifiers (Cmd/Shift/Opt/Ctrl) highlight immediately,
and — in Phase B — the hotdox's active QMK layer switches the displayed
layer automatically via a Raw HID bridge. Zero polling, negligible CPU, no
new runtime dependencies beyond what is already installed.


## Glossary [RECOMMENDED]

- **Widget**: the pair of Hammerspoon `hs.webview` windows rendering
  `index.html` at desktop level — one webview per Board, stacked vertically
  on the Portrait display (hotdox on top, Creator Micro below).
- **Portrait display**: the Dell S2725HS side monitor in portrait
  orientation (1080×1920 effective) — the Widget's home.
- **Board**: one of the two keyboards in the visualizer — `hd` (hotdox76v2)
  or `cm` (Creator Micro), as already named in `index.html` (`app-hd`,
  `app-cm`, `showBoard('hd'|'cm')`).
- **Layer**: a QMK layer (hotdox: 0–4, Creator Micro: 0–3), matching the
  existing `layer` variables and tab UI in `index.html`.
- **Modifier state**: the set of currently-held OS modifiers as reported by
  macOS (`cmd`, `alt`, `shift`, `ctrl`, `fn`) — host-side, keyboard-agnostic.
- **Widget mode**: a rendering mode of `index.html` (activated via URL hash)
  that hides masthead/notes/legend chrome and shows only the board, sized to
  fill the window.
- **HID bridge**: Phase B host-side listener that receives layer-change
  messages from the hotdox over Raw HID and forwards them to the Widget.


## Scope [REQUIRED]

### In Scope

- **Phase A (no firmware changes):**
  - Widget mode in `index.html`: hash suffix `&widget` (e.g. `#micro&widget`)
    hides all chrome except the board and scales the board to the window.
  - A small JS API in `index.html` callable from Hammerspoon:
    `window.__setMods({cmd,alt,shift,ctrl,fn})` and `window.__setLayer(n)`.
  - Hammerspoon module `keymap-widget.lua` (new file in
    `~/.dotfiles/macos/hammerspoon/`, loaded via `dofile` from `init.lua`)
    that creates TWO webviews at desktop level on the Portrait display —
    `#hotdox&widget` on top, `#micro&widget` below — on all spaces, and
    feeds both modifier events from a single `flagsChanged` eventtap.
  - Screen watching (`hs.screen.watcher`): if the Portrait display is
    absent (laptop undocked), the webviews hide; they reappear when it
    reconnects. No fallback placement on other screens.
  - Shift behavior: while Shift is held, tap legends display shifted glyphs
    (number row → symbols, etc.) on the active layer.
  - Cmd/Opt/Ctrl/Fn behavior: the corresponding physical modifier keys on the
    board render in a "held" style. No legend remapping for these in v1.
  - A Hammerspoon hotkey (⌘⌃K) toggling widget visibility, plus a
    `keymapWidget.toggle()` function reachable via the `hs` CLI (hs.ipc is
    already loaded).
  - **Per-keypress flash (v1.2, optional at runtime):** a second, separate
    keyDown/keyUp eventtap sends `window.__flashKey(token, down)`; the page
    flips a `press` class on pre-indexed keycap nodes — no re-render, no
    timers, autorepeat events dropped. ⌘⌃⇧K / `keymapWidget.toggleKeys()`
    starts/stops the tap itself, so "off" costs literally nothing; turning
    it off also clears any keycap left lit. On by default. On the micro,
    F13–F19 keycodes flash the matching macro keys. Mod-tap letters (home
    row) reach the OS as a ~1ms down+up pair once QMK resolves the tap, so
    flashes are stretched to a ~140ms visible minimum via a one-shot decay
    timeout (event-driven, not polling); press state lives in a set that
    survives the full re-renders triggered by modifier changes.
- **Phase B (hotdox only, requires reflash):**
  - `layer_state_set_user` in
    `/Users/marcosandrade/qmk_firmware/keyboards/hotdox76v2/keymaps/mrx/keymap.c`
    broadcasting `[0x4C, layer]` via `raw_hid_send` on every layer change
    (and once on startup/wake). VIA is already enabled
    (`VIA_ENABLE = yes` in that keymap's `rules.mk`), which forces
    `RAW_ENABLE` on — no `rules.mk` change needed, and our code MUST NOT
    define `raw_hid_receive` (VIA owns it).
  - Host listener script `~/.dotfiles/macos/scripts/keymap-widget-hid.py`
    (Python + `hidapi`) that ignores frames whose first byte is not `0x4C`
    (VIA protocol traffic shares the endpoint) and prints one line per
    layer change to stdout; Hammerspoon runs it with `hs.task` and forwards
    each line to `__setLayer(n)` on the hotdox webview only.
  - Reconnect-with-backoff when the board is unplugged/replugged or the
    machine wakes from sleep.

### Out of Scope (Non-Goals)

- Creator Micro layer sync — it stays on stock Work Louder VIA firmware; its
  widget reacts to OS modifiers only and layer is switched manually.
- ~~Per-keypress highlighting (lighting up every key as it is typed).~~
  *Promoted to in-scope in v1.2 as a runtime-toggleable extra (⌘⌃⇧K) — see
  Phase A scope. Caveat stands: the OS reports the keycode the board sent,
  so keys are matched against the currently displayed layer's legends;
  layer-shifted output (before Phase B) and non-QWERTY host input sources
  can mismatch.*
- Any change to the keymaps themselves — this renders state, it does not
  remap anything. The "Proposed" hotdox layout toggle is untouched.
- Übersicht, Electron, SwiftUI, menu-bar apps, or any new widget framework.
  Hammerspoon is the only host.
- Configurable placement or a settings/preferences UI. The Widget lives on
  the Portrait display only, with hardcoded geometry constants at the top
  of `keymap-widget.lua`. If that display is missing, the Widget hides —
  no fallback to other screens.
- Typing statistics, heatmaps, key-frequency tracking.
- Windows/VENGEANCE support (kanata has its own layer story; separate effort).


## User Stories & Acceptance Criteria [REQUIRED]

### Story 1: Widget on the wallpaper

**As a** user at my desk, **I want** both boards rendered on the portrait
monitor's wallpaper layer **so that** I can glance at my bindings without
opening anything.

**Acceptance Criteria:**
- [ ] After `hs.reload()`, chrome-less renders of the hotdox (top) and
      Creator Micro (below) appear on the Portrait display at desktop
      level (above wallpaper, below all normal windows).
- [ ] Undocking (Portrait display gone) hides the webviews without errors;
      redocking brings them back without a manual reload.
- [ ] The widget appears on every Space (canJoinAllSpaces) and does not
      steal focus when clicked.
- [ ] ⌘⌃K hides/shows it; state survives Hammerspoon reload (recreated
      visible by default).
- [ ] `open index.html` in a browser still works exactly as before — widget
      mode only activates with the `&widget` hash suffix.

### Story 2: Live modifier highlighting

**As a** user holding a modifier, **I want** the widget to reflect it
immediately **so that** the board always shows what my keys will do.

**Acceptance Criteria:**
- [ ] Holding Shift swaps tap legends to shifted glyphs; releasing restores
      them. Perceived as instant (single evaluateJavaScript per flagsChanged
      event; no timers, no polling).
- [ ] Holding Cmd/Opt/Ctrl highlights those physical mod keys on the board.
- [ ] Works regardless of which physical keyboard produced the modifier
      (hotdox, Creator Micro, built-in).
- [ ] With Accessibility permission missing, Hammerspoon logs a clear
      warning and the widget still renders statically (no crash loop).

### Story 3: Live hotdox layer tracking (Phase B)

**As a** hotdox user, **I want** the widget to switch to the layer I am
actually on **so that** momentary/toggled layers (Symbols, Nav, System) show
their real bindings while held.

**Acceptance Criteria:**
- [ ] Holding a layer key on the hotdox switches the widget to that layer's
      tab; releasing returns it to base. Same rendering path as clicking the
      layer tab manually.
- [ ] Unplugging the board does not crash the listener; the widget falls
      back to layer 0 and modifier highlighting keeps working. Replugging
      resumes layer tracking within 5 seconds without a Hammerspoon reload.
- [ ] Flashing the updated firmware does not change any key behavior — the
      keymap diff is additive (`layer_state_set_user` + raw HID plumbing
      only).


## Technical Specification [REQUIRED]

### API / Interface Contracts

JS API added to `index.html` (global, plain functions — the file stays
self-contained, no modules, no build step):

```
window.__setMods(flags)
  Input:  flags: {cmd:bool, alt:bool, shift:bool, ctrl:bool, fn:bool}
  Effect: toggles a `held` CSS class on matching mod keys of the visible
          board; if flags.shift, re-renders tap legends with shifted glyphs.
  Errors: never throws; unknown fields ignored.

window.__setLayer(n)
  Input:  n: integer layer index for the visible board
  Effect: sets the board's `layer` variable and calls its render() —
          identical code path to clicking the layer tab.
  Errors: out-of-range n is clamped/ignored, never throws.

window.__flashKey(token, down)                                      [v1.2]
  Input:  token: canonical key name — single chars ("a", "7", ";"), named
          keys ("space", "enter", "bksp", "tab", "esc", "del", "left",
          "right", "up", "down", "home", "end", "pgup", "pgdn"), or
          "f13".."f19" (creator micro macros); down: bool.
  Effect: toggles a `press` CSS class on the matching keycap node(s) of the
          visible board via a token→nodes index rebuilt on each render.
          No re-render — this is the hot path.
  Errors: unknown token is a no-op, never throws.
```

Widget mode activation (hash only — file:// URLs make query strings
unreliable, and the page already routes on hash):

```
index.html#micro&widget    → Creator Micro, widget mode
index.html#hotdox&widget   → hotdox, widget mode
Parsing: hash.includes('micro') picks the board (existing behavior),
         hash.includes('widget') enables widget mode.
```

Phase B raw HID message, firmware → host:

```
Direction: raw_hid_send from keymaps/mrx/keymap.c
Trigger:   layer_state_set_user (every change) + keyboard_post_init_user
Payload:   byte[0] = 0x4C ('L'), byte[1] = highest active layer (0–4),
           remaining bytes zero.
Listener:  keymap-widget-hid.py opens the device by VID/PID + usage page
           0xFF60 / usage 0x61, blocking-reads, prints "L<n>\n" per message.
```

### UI/UX Specifications

- **Widget mode**: hides `header`, `.legend`, notes/aside sections, board
  switcher, and layer-tab row is kept (small) so manual layer browsing still
  works with a mouse. Board scales via the existing `fit()` functions.
- **Held-modifier style**: same visual language as the existing key-class
  system (`#app-cm .key.violet` pattern at `index.html:277` — add a `.held`
  class with a brighter border/background rather than inventing a new
  system).
- **Hammerspoon window**: `hs.webview` with
  `hs.drawing.windowLevels.desktopIcon` level,
  `canJoinAllSpaces` behavior — mirroring the level/behavior idioms already
  used by `layoutHUD` in `init.lua`.

### State Management

- Modifier state lives only in the eventtap callback; the webview is a dumb
  renderer receiving `__setMods` calls. No state files, no persistence.
- Layer state (Phase B) lives in the firmware; host merely relays. On
  listener restart, the firmware's post-init broadcast (or a fallback
  `__setLayer(0)`) resyncs.
- Widget placement: hardcoded constants at the top of `keymap-widget.lua`
  (Portrait display identified by `hs.screen.find("S2725HS")` or its name,
  plus the two window rects). Changing layout is an edit + `hs.reload()`,
  not a UI.
- Modifier events fan out to both webviews; `__setLayer` (Phase B) goes to
  the hotdox webview only.


## Constraints & Decisions [RECOMMENDED]

### Technical Constraints

- `index.html` MUST remain a single self-contained file with no build step
  and no external dependencies (stated project identity in `README.md`).
- Hammerspoon is the ONLY host process for the widget. No launchd agents for
  Phase A. Phase B's Python listener is spawned and supervised by
  Hammerspoon via `hs.task`, not launchd.
- MUST be event-driven end to end: `flagsChanged` eventtap + blocking HID
  reads. NO `hs.timer` polling loops.
- New Hammerspoon code goes in
  `~/.dotfiles/macos/hammerspoon/keymap-widget.lua`, loaded from `init.lua`
  with `dofile(os.getenv("HOME") .. "/.dotfiles/macos/hammerspoon/keymap-widget.lua")`
  — bootstrap.sh only symlinks `init.lua`, so `dofile` by absolute path
  avoids touching bootstrap.
- Phase B firmware change MUST be confined to `keymaps/mrx/keymap.c`. No
  `rules.mk` change (`VIA_ENABLE = yes` already implies `RAW_ENABLE`), no
  `raw_hid_receive` definition (VIA owns it), and no changes to shared
  files under `keyboards/hotdox76v2/`.
- Python listener MUST use only `hidapi` (`pip install hidapi`) beyond the
  stdlib.

### Decisions Already Made

- **Decision**: Hammerspoon webview, not Übersicht.
  - **Why**: Hammerspoon is already running, already has `hs.ipc`, and the
    eventtap must live there anyway — one process instead of two.
  - **Rejected alternative**: Übersicht (extra dependency, still needs
    Hammerspoon for eventtap → cross-process plumbing for no gain).
- **Decision**: Reuse `index.html` as the widget UI via widget mode.
  - **Why**: the board geometry, layer data, and rendering already exist and
    are maintained here; duplicating them in Lua/canvas would rot.
  - **Rejected alternative**: native `hs.canvas` re-implementation.
- **Decision**: OS-level modifier tracking (Phase A) is separate from
  firmware layer tracking (Phase B), and Phase A ships alone first.
  - **Why**: Phase A is zero-risk (no reflash) and delivers most of the
    glanceable value; Phase B has a flash-and-test loop.
- **Decision**: Board→host push over Raw HID, not host polling or
  keypress inference.
  - **Why**: this is the established pattern (ZSA Keymapp); inference from
    keypresses is fragile and polling wastes cycles.
- **Decision**: Two webviews (one per board), not a combined `#both` mode
  in `index.html`.
  - **Why**: reuses the existing per-board hash routing and `fit()` logic
    untouched; stacking/positioning is trivial in Hammerspoon; layer events
    have an unambiguous target window.
  - **Rejected alternative**: a `#both&widget` mode rendering both `app-hd`
    and `app-cm` in one page (more page surgery for no functional gain).
- **Decision**: Coexist with VIA on the shared Raw HID endpoint.
  - **Why**: `VIA_ENABLE = yes` is already in the mrx build and keeps the
    usevia.app workflow; outbound-only `raw_hid_send` frames tagged `0x4C`
    don't interfere with VIA's request/response protocol, and the listener
    filters to that tag.
  - **Rejected alternative**: dropping VIA to get a private endpoint.


## Edge Cases & Error Handling [RECOMMENDED]

- **Secure input active (password fields)**: macOS suppresses event taps;
  the widget freezes in its last modifier state. Accepted — no workaround.
- **Accessibility permission revoked**: `hs.eventtap:start()` fails →
  `hs.printf` warning once; widget renders without live modifiers.
- **Hammerspoon reload while HID listener running**: `hs.task` child is
  terminated on reload (register in `hs.shutdownCallback`); the new instance
  respawns it. No orphan processes.
- **hotdox unplugged / machine sleeps**: listener's open/read fails → it
  exits with a distinct message; Hammerspoon respawns it with backoff
  (2s, 4s, 8s, max 30s) and calls `__setLayer(0)` meanwhile.
- **Widget mode hash on a browser (not in widget)**: works identically —
  widget mode is pure CSS/JS, nothing Hammerspoon-specific in the page.
- **`evaluateJavaScript` before page load finishes**: queue the first
  `__setMods` call behind each webview's navigation-complete callback.
- **usevia.app open while the listener runs**: both can read the endpoint;
  the listener drops non-`0x4C` frames, and VIA ignores our frames in
  practice. If VIA misbehaves during a config session, stopping the
  listener temporarily is the documented workaround — do not build
  automatic VIA detection.
- **Portrait display disconnected**: webviews hide via `hs.screen.watcher`
  callback; no repositioning to other screens, no errors logged per event.


## Dependencies & Ordering [RECOMMENDED]

1. Widget mode + JS API in `index.html` — blocks 2 and 4; verifiable alone
   in a browser via DevTools console.
2. `keymap-widget.lua` webview + eventtap + toggle hotkey — depends on 1.
   **Phase A complete here.**
3. Firmware: `layer_state_set_user` + raw HID send in `keymap.c`, flash —
   independent of 1–2; verifiable alone with `hid_listen`/a REPL.
4. `keymap-widget-hid.py` + `hs.task` wiring — depends on 2 and 3.
   **Phase B complete here.**


## Files to Modify [RECOMMENDED]

### Files to Change

- `index.html` — widget mode (hash flag + chrome hiding), `__setMods`,
  `__setLayer`, `.held` key style.
- `~/.dotfiles/macos/hammerspoon/keymap-widget.lua` — NEW: webview creation,
  eventtap, toggle hotkey, (Phase B) hs.task supervision of the listener.
- `~/.dotfiles/macos/hammerspoon/init.lua` — one `dofile` line.
- `README.md` (this repo) — document widget mode hash and the JS API.
- *(Phase B)*
  `/Users/marcosandrade/qmk_firmware/keyboards/hotdox76v2/keymaps/mrx/keymap.c`
  — layer broadcast (`rules.mk` stays untouched).
- *(Phase B)* `~/.dotfiles/macos/scripts/keymap-widget-hid.py` — NEW.

### Files to Reference (read-only, for patterns)

- `~/.dotfiles/macos/hammerspoon/init.lua` — window level/behavior idioms
  (`layoutHUD`), `hs.pathwatcher`/callback style, existing ⌘⌃L hotkey (new
  hotkey must not collide).
- `index.html:706` and `index.html:943` — the two boards' `layer` state and
  `render()` functions `__setLayer` must reuse.
- `index.html:1045` `showBoard()` — hash-routing pattern to extend.
- `~/.dotfiles/macos/skhd/skhdrc` — confirm ⌘⌃K is unbound.


## Testing Strategy [RECOMMENDED]

### Automated Tests

None. This project has no test harness and a single HTML file; verification
is manual. Do not introduce a test framework for this feature.

### Manual Verification

- [ ] Open `index.html#micro&widget` in Safari: only the board + layer tabs
      render; console: `__setMods({shift:true})` shows shifted legends,
      `__setLayer(2)` switches layers, `__setLayer(99)` is a no-op.
- [ ] Open `index.html` plain: identical to pre-change behavior.
- [ ] `hs.reload()`: widget appears on wallpaper, all Spaces; ⌘⌃K toggles.
- [ ] Hold Shift/Cmd in another app (e.g. while using Emacs): widget updates.
- [ ] *(Phase B)* `python3 keymap-widget-hid.py` standalone prints `L1`,
      `L2`… while holding hotdox layer keys.
- [ ] *(Phase B)* unplug/replug hotdox: widget recovers within 5s.


## Success Criteria [REQUIRED]

- [ ] All acceptance criteria in Stories 1–2 pass (Phase A done).
- [ ] All acceptance criteria in Story 3 pass (Phase B done).
- [ ] `index.html` opened with no hash behaves byte-for-byte like before in
      normal browsing (no console errors, hotdox default, switcher works).
- [ ] Hammerspoon console shows no errors after `hs.reload()`.
- [ ] `ps` shows zero widget-related processes other than Hammerspoon
      (Phase A) / Hammerspoon + one python listener (Phase B).
- [ ] Activity Monitor: Hammerspoon CPU at idle with widget visible is
      indistinguishable from before (event-driven claim holds).
- [ ] Typing all keymap layers on the hotdox produces correct on-widget
      layer switches with no missed transitions in a 2-minute stress test.


## Anti-Patterns [OPTIONAL]

- Do NOT split `index.html` into separate JS/CSS files or add a bundler.
- Do NOT re-implement board rendering in Lua/`hs.canvas`.
- Do NOT add polling timers anywhere — if state seems stale, fix the event
  path.
- Do NOT touch the Creator Micro's firmware or its VIA configuration.
- Do NOT modify the keymaps' actual bindings, the "Proposed" layout data, or
  anything under `keyboards/hotdox76v2/` in the QMK checkout.
- Do NOT add a launchd agent, menu-bar item, login item, or preferences UI.
- Do NOT create the widget as a focusable window — it must never appear in
  Cmd-Tab or steal keyboard focus.
