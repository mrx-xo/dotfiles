# mrx keymap explorer

Interactive visualizer for the **Keebio Iris SE** (USB name `Iris Rev. 8`,
RP2040, QMK target `keebio/iris/rev8`): one self-contained HTML file, no
build, no dependencies. Walk the layers, hover any key for its QMK keycode,
and compare the current layout side by side against Factory.

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
- **Current v1** (on board, flashed 2026-09-28) and **Factory** (Keebio
  default QWERTY, retired). Side by side rings every key that differs.
- The left inner key (#42) is a rotary knob: press legend plus per-layer
  turn actions from `encoder_map`.

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
