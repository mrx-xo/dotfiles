# mrx keymap explorer

Interactive visualizer for my boards — one self-contained HTML file, no build,
no dependencies. A switcher in the masthead flips between the two boards
(deep-linkable: `index.html#hotdox` / `index.html#micro`).

**Where this is all going: [ROADMAP.md](ROADMAP.md)** — layout decisions
left, widget Phase B, and the single flash that ships both.

## hotdox76v2

My **hotdox76v2** (ErgoDox) QMK keymap — Dvorak with home-row mods. Flip
between the **current** layout and a **proposed** cleanup, walk the layers,
and hover any key for its QMK keycode.

## creator micro

The Work Louder **Creator Micro** macropad — scroll wheel + big knob + 12 keys
+ 2 touch pads, 4 layers:

- **0 Agents** — agent-shell allow/deny/diff pad (F13/F14/F16 → skhd → emacsclient)
- **1 Spotify** — transport + launch macros
- **2 Monitors** — F17–F19 → `monitor-mode.sh` display flips
- **3 RGB** — Work Louder per-key matrix controls (`CUSTOM(0-6)`)

Parsed from `creator_micro_v1.layout.json` (VIA export); F-key meanings
resolved against `~/.dotfiles/macos/skhd/skhdrc`.

## Run

```bash
open index.html            # hotdox by default; #micro opens the creator micro
```

## Widget mode

Appending `&widget` to the hash (`index.html#hotdox&widget` /
`index.html#micro&widget`) strips all chrome except the board and a small
layer-tab row, and scales the board to fill the window. This is how the
Hammerspoon wallpaper widget (`~/.dotfiles/macos/hammerspoon/keymap-widget.lua`)
renders both boards on the portrait display — see `live-keymap-widget-prd.md`.
⌘⌃K toggles the widget; `hs -c "keymapWidget.toggle()"` does the same.

Two globals let Hammerspoon (or the DevTools console) drive the page:

```js
__setMods({cmd, alt, shift, ctrl, fn})  // highlight held mods; shift also
                                        // swaps tap legends to shifted glyphs
__setLayer(n)                           // switch layer, same path as the tabs;
                                        // out-of-range n is a no-op
__flashKey(tok, down)                   // flash a keycap as it's typed, e.g.
                                        // ("a", true) / ("f13", true); class
                                        // flip only, no re-render
```

Per-keypress flash is on by default; ⌘⌃⇧K (or
`hs -c "keymapWidget.toggleKeys()"`) turns it on/off — off stops the
eventtap entirely, so it costs nothing when disabled.

Both work in any mode, never throw, and touch nothing when the page is used
as a plain document.

## What it shows

- **Current vs Proposed** toggle — the proposal only touches dead keys,
  duplicates, and empty layer space; alphas never move.
- **Layers**: 0 Base · 1 Symbols · 2 Nav · 3 System · 4 Game
- **Reachability notes** — e.g. current Layer 3 (BOOT) has no activator; the
  proposal reaches it via a Space+Enter tri-layer.
- Per-key legend for hold-layers, Hyper/Meh, dead keys, transparent keys, and
  what changed in the proposal.

## Source of truth

- Geometry: `LAYOUT_ergodox_pretty` from `keyboards/hotdox76v2/keyboard.json`
- Current layers parsed from `keymaps/mrx/keymap.c` (commit `8eb6039`)
- Proposal needs `EXTRAKEY_ENABLE` + tri-layer to flash
