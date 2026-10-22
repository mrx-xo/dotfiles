# mrx keymap explorer

Interactive visualizer for the **Keebio Iris SE** (USB name `Iris Rev. 8`,
RP2040, QMK target `keebio/iris/rev8`) and the **KOMAX** macro pad (Keychron
K0 Max): static HTML/CSS/JavaScript, no build or runtime dependencies. Walk
the layers, compare layout versions, or practice your actual Emacs leader
bindings in short recall rounds. The **board** picker at the top switches
between them.

The hotdox76v2 and the Creator Micro used to live here too. Both boards are
gone (2026-08-03); their explorers, ledgers and flashing runbook are in git
history up to `c39eb8b`. KOMAX took over the Creator Micro's slot on
2026-10-21: page, widget, ledger and docs.

- **Next steps: [ROADMAP.md](ROADMAP.md)**
- **Version ledger: [VERSIONS.md](VERSIONS.md)**
- **Flashing runbook: [FLASHING.md](FLASHING.md)**

## Run

```bash
agent-open "file://$HOME/.dotfiles/macos/keymap-explorer/index.html"
```

`#idx` in the hash numbers every key (0-55, `LAYOUT` order), same as the
`key #s` button. `#komax` opens the KOMAX board (`#komax&idx` numbers its
keys 0-26).

## What it shows

- **Layers**: 0 Base · 1 Symbols · 2 Nav · 3 System · 4 Game · 5 Emacs
  (proposed only)
- **Current v2** (on board, flashed 2026-09-29), **Proposed v3** (draft,
  not flashed), and **Factory** (retired). Side by side compares layouts.
- **Proposed changes** always compare against Current v2, in Single view
  or on either side of Side by side. Changed keys have a dedicated cyan fill,
  thick outline, and a `Δ` marker, distinct from layer colours. The light theme
  uses a darker cyan accent with deeper text for contrast. Layer tabs show
  change counts; the selected layer's summary explicitly identifies layers
  with no changes.
- The left inner key (#42) is a rotary knob: press legend plus per-layer
  turn actions from `encoder_map`.
- **Proposed screenshot key**: hold Space + Enter (System), tap the Base
  `S` position (#34), labeled `Shot · Area`. `LSG(KC_4)` sends Cmd+Shift+4
  to start CleanShot X area selection using its existing shortcut. Explorer
  draft only: Current v2 and the firmware remain unchanged.

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

## KOMAX (Keychron K0 Max)

A 27-key numpad with a macro column and a knob (USB `0x3434:0x0A06`, QMK
under Keychron's own firmware). Layers 0 Base and 1 Fn.

- **Stock** is what is on the pad: Keychron's `keymaps/default`. M1 to M4 are
  empty macro slots that send nothing, and the bottom-left key is **Fn**
  (`MO(1)`), not a fifth macro key.
- **Proposed v1 (draft d1)** is the desk grammar from
  `docs/active/plans/2026-10-21-komax-desk-grammar.md`: blue screen keys
  (ROMULUS, REMUS, NYX) arm, coloured machine keys (POLLUX green, NEMESIS
  red, the knob press WORK amber) fire. Unchanged keys are greyed in this
  view, and the Fn tab says why Fn is unreachable once the plan's M5 lands
  on #23.
- **Legend only, no live layer tracking.** The KOMAX keymap does not send
  the `[0x4C, layer]` raw-HID frame the Iris firmware broadcasts, so the
  widget stays on Base. Key flash works: numpad keys arrive as `pad7`,
  `pad*`, `padclear` and so on, and F13 to F19 as `f13` to `f19`.
- **Compiled firmware, flashed like the Iris** (decided 2026-10-22; Launcher
  is out, `VIA_ENABLE = no`). Keymap `keyboards/keychron/k0_max/keymaps/mrx/`
  in `~/qmk_keychron`, a checkout of Keychron's QMK fork (branch `2025q3`,
  local branch `mrx`). See the KOMAX section in `FLASHING.md`; after a flash
  record it in the KOMAX ledger in `VERSIONS.md` and update `cur0`/`cur1` in
  the KOMAX block of `index.html`.
- Geometry is `LAYOUT_tenkey_27` from `keyboards/keychron/k0_max/keyboard.json`;
  the stock layers come from `keymaps/default/keymap.c`.
- **Night lights.** Both boards answer `keyboard-lights off|on`
  (`macos/scripts/keyboard-lights`): a raw-HID frame, tag `0x4E`, that
  darkens the lighting and later restores the saved look without touching
  EEPROM. "good night" / "good morning" reach it through Home Assistant and
  `mon-voice-gate.sh`. Design: `docs/active/specs/2026-10-22-keyboard-flash-day-design.md`.

## Widget mode (the wallpaper overlay)

`index.html#widget` strips all chrome except the board and a small
layer-tab row, and scales the board to fill the window; `#komax&widget` does
the same for KOMAX. The Hammerspoon wallpaper widget
(`~/.dotfiles/macos/hammerspoon/keymap-widget.lua`) renders both on the
portrait Dell, the Iris on top and KOMAX centred below it. See
`live-keymap-widget-prd.md`.

- The summoned overlay (⌘⌃⌥K) shows the **Iris only**; KOMAX hides while it
  is up and returns to the wallpaper on dismiss.

- ⌘⌃K (or `hs -c "keymapWidget.toggle()"`) hides and shows it.
- ⌘⌃⌥K (`Cmd+Ctrl+Alt+K`, or `hs -c "keymapWidget.toggleOverlay()"`)
  summons a translucent floating panel on yabai's currently focused display.
  Press again to return to the previous wallpaper/hidden state. Summoning
  leaves keyboard focus in your working app; layer tracking and key flashes
  continue using the same webview.
- **Meh + 1–5** selects a display before summoning. While the overlay is
  visible, **Hyper + 1–5** moves it to that display and follows it, using
  the same current yabai numbering as skhd. With the overlay closed, those
  keys move the focused application as usual. Display focus can select a
  different application on the destination, just like the existing shortcut.
  An unavailable destination leaves the overlay in place. If its monitor
  disconnects, it relocates to the focused display (or the main display).
- ⌘⌃⇧K (or `hs -c "keymapWidget.toggleKeys()"`) turns per-keypress flash
  on and off. Off stops the eventtap entirely.
- Live layer tracking reads the firmware's raw HID broadcast through
  `~/.dotfiles/macos/scripts/keymap-widget-hid.py`. It needs the broadcast
  build flashed (see ROADMAP.md); until then the widget stays on Base and
  the listener retries every 30 s.

The floating panel stays above ordinary app windows and requests full-screen
auxiliary behavior; native full-screen apps need separate live verification.
Wallpaper mode still belongs to the portrait display. Its visibility toggle
changes the saved wallpaper state while the floating panel is open.

After editing the widget host, reload Hammerspoon with `hs -c 'hs.reload()'`;
after editing shortcuts, run `skhd --reload`. Reloading Hammerspoon returns
to visible wallpaper mode. If Hyper-number routing fails, check
`macos/scripts/keymap-display.sh`: it falls back to ordinary yabai window
movement when Hammerspoon is stopped. An IPC timeout or error leaves apps in
place instead of guessing which window to move. Dismiss the overlay to restore
normal window targeting without changing any configuration.

Regression checks for display routing and presentation state:

```bash
python3 ~/.dotfiles/macos/scripts/tests/keymap-display.test.py
```

```bash
hs -c 'dofile(os.getenv("HOME") .. "/.dotfiles/macos/hammerspoon/tests/keymap-widget-test.lua")'
```

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
