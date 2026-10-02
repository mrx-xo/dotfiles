# mrx keymap explorer

Interactive visualizer for the **Keebio Iris SE** (USB name `Iris Rev. 8`,
RP2040, QMK target `keebio/iris/rev8`): static HTML/CSS/JavaScript, no build
or runtime dependencies. Walk the layers, compare layout versions, or practice
your actual Emacs leader bindings in short recall rounds.

The hotdox76v2 and the Creator Micro used to live here too. Both boards are
gone (2026-08-03); their explorers, ledgers and flashing runbook are in git
history up to `c39eb8b`.

- **Next steps: [ROADMAP.md](ROADMAP.md)**
- **Version ledger: [VERSIONS.md](VERSIONS.md)**
- **Flashing runbook: [FLASHING.md](FLASHING.md)**

## Run

```bash
agent-open "file://$HOME/.dotfiles/macos/keymap-explorer/index.html"
```

`#idx` in the hash numbers every key (0-55, `LAYOUT` order), same as the
`key #s` button.

## What it shows

- **Layers**: 0 Base · 1 Symbols · 2 Nav · 3 System · 4 Game
- **Current v2** (on board, flashed 2026-09-29) and **Factory** (retired).
  Side by side rings differing keys.
- The left inner key (#42) is a rotary knob: press legend plus per-layer
  turn actions from `encoder_map`.

## Practice

Refresh bindings from the running Emacs and open the Practice view:

```bash
~/.dotfiles/macos/keymap-explorer/practice.sh
```

Choose **Start a round** for ten command prompts. Type each command's leader
sequence; press **Enter** (or click **Reveal keys**) to show the sequence and highlight the next key on
the current Dvorak Iris. Correct alternate bindings for the same command count
too, except in an explicitly labeled single-binding drill. Wrong input resets
the sequence. Accuracy counts
correct keypresses / all attempted keypresses; streaks and recalled commands
count only answers without mistakes or hints. Revealing keys does not add a
mistake or lower accuracy. The Enter shortcut works while the practice keyboard
has focus; it does not intercept controls or search. **Escape** pauses, **Tab** leaves
the capture area, and losing window focus pauses. **End round** returns to deck
selection; completed answers remain saved. Commands are never executed.

**New & rusty** favors unpracticed and missed bindings, with no consecutive
identical card when alternatives exist. **Needs practice** contains attempted
bindings until three consecutive unaided recalls; hints or mistakes reset that
run. Choose a leader prefix to narrow the
deck, or expand **Find a binding** and click **Practice** beside one command
to drill that exact binding. Theme choices are Gruvbox (default), Gruvbox light,
and Midnight. Themes and progress stay in browser localStorage; opening the
same files in a different browser/origin starts a separate history. If storage
is blocked, rounds still work with session-only progress.

The catalog is a **timestamped snapshot**, not a live feed. It reads effective
`SPC` bindings in a disposable `fundamental-mode` buffer in Evil normal state.
It does not change keymaps or visit user buffers. Only printable sequences are
included: OS/browser shortcuts, Hyper chords, special-key sequences, and
mode-specific bindings need a future native capture path. Hints show emitted
keys; the browser cannot prove which physical mod-tap or QMK layer you used.
Practice follows current firmware, not proposed draft layouts.

After adding or changing bindings, rerun the launcher, or refresh without
opening a page and then reload the browser:

```bash
~/.dotfiles/macos/keymap-explorer/practice.sh --refresh-only
```

`practice-bindings.js` is generated locally and gitignored. Export failure
preserves the previous file and the launcher exits with an error. If no export
exists, Practice displays the launcher command. If the catalog looks stale,
confirm your latest bindings are loaded in the daemon and rerun the launcher;
no daemon restart is needed. Clear this page's browser site data to reset local
progress and theme. Switching back to **Explore** restores the layer explorer;
`#widget` keeps the existing wallpaper UI and APIs.

The earlier [typing-practice](https://github.com/mrx-xo/typing-practice) project
informed the feedback loop. Practice uses this explorer's accurate Iris geometry
and current legends instead of that project's separate rectangular keyboard.

### Verification

```bash
node --test ~/.dotfiles/macos/keymap-explorer/tests/practice.test.cjs
```

`tests/browser.cjs` runs a full round and checks focus, hints, storage, themes,
search, layout versions, responsive sizing, and widget APIs using Playwright.
Set `PLAYWRIGHT_MODULE` to an existing Playwright installation and optionally
`BROWSER_EXECUTABLE` to the browser binary for a headless run. The browser suite
requires a generated local catalog; no test dependencies ship with the page.

## Widget mode (the wallpaper overlay)

`index.html#widget` strips all chrome except the board and a small
layer-tab row, and scales the board to fill the window. The Hammerspoon
wallpaper widget (`~/.dotfiles/macos/hammerspoon/keymap-widget.lua`) renders
it on the portrait Dell. See `live-keymap-widget-prd.md`.

- ⌘⌃K (or `hs -c "keymapWidget.toggle()"`) hides and shows it.
- ⌘⌃⇧K (or `hs -c "keymapWidget.toggleKeys()"`) turns per-keypress flash
  on and off. Off stops the eventtap entirely.
- Live layer tracking reads the firmware's raw HID broadcast through
  `~/.dotfiles/macos/scripts/keymap-widget-hid.py`. It needs the broadcast
  build flashed (see ROADMAP.md); until then the widget stays on Base and
  the listener retries every 30 s.

Three globals let Hammerspoon (or the DevTools console) drive the page:

```js
__setMods({cmd, alt, shift, ctrl, fn})  // highlight held mods; shift also
                                        // swaps tap legends to shifted glyphs
__setLayer(n)                           // switch layer, same path as the tabs;
                                        // out-of-range n is a no-op
__flashKey(tok, down)                   // flash a keycap as it's typed, e.g.
                                        // ("a", true); class flip only
```

All three never throw, and touch nothing when the page is used as a plain
document.

## Source of truth

- Keymap: `~/qmk_firmware/keyboards/keebio/iris/keymaps/mrx/keymap.c`
  (the explorer's `cur0`-`cur4` mirror it key for key)
- Geometry: `LAYOUT` from `keyboards/keebio/iris/rev8/keyboard.json`
- Factory layers: `keyboards/keebio/iris/keymaps/default/keymap.json`
