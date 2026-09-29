# Layout version ledger

One integer per **flashed** layout, forever incrementing. "What version is on
the board?" is answered here and in the explorer's eyebrow and footer.

A flash promotes a draft: it gets a keymap.c reference and a flash date here,
the old current is marked retired, and the explorer's `cur` maps are updated
to match `keymap.c`.

The hotdox76v2 (v1-v4 draft) and Creator Micro (v1-v5 draft) ledgers are in
git history up to `c39eb8b`. Both boards died on 2026-08-03.

## Ledger: Keebio Iris SE (keebio/iris/rev8)

### Factory: retired 2026-09-28
- Keebio default keymap, VIA on (live keymap in EEPROM).
- QWERTY, Grave-Esc, thumbs ⌘ Lower Enter | Space Raise ⌥.

### v1: retired 2026-09-29
- Only ever reached the right half; the left half stayed on factory
  firmware until the v2 flash (found 2026-09-29: with the cable in the left
  half, the home row typed QWERTY).
- keymap: `~/qmk_firmware/keyboards/keebio/iris/keymaps/mrx/` (not yet
  committed in `qmk_firmware`)
- Port of hotdox v3 (`c6b22e1`): Dvorak and all ten home-row mods key for
  key; Symbols, System (Space + Enter tri-layer) and Game unchanged.
- #42 (left inner) is a knob: volume on base, Prev/Next on Symbols,
  Tab◀/Tab▶ on Nav, brightness on System.
- What 56 keys could not hold on base moved to Nav: Agenda, Recent,
  Scratch, Layout on the left number row; Caps Word on Tab; Nav LOCK on
  Shift.
- `VIA_ENABLE = no`: the compiled keymap is the only one.

### v2: on board, flashed 2026-09-29 (both halves, verified)
- v1 layout plus the raw HID layer broadcast
  (`[0x4C, layer]`, master half only) for the wallpaper widget.
  `RAW_ENABLE = yes`.
- Tab comes back to the thumb (2026-09-29): #53 (right inner thumb)
  Esc -> `KC_TAB`; #43 (inner right) `MO(1)` -> `LT(1, KC_ESC)`, tap Esc,
  hold Symbols. Esc also stays on the #0 corner. If the #43 Esc misfires in
  Evil (Symbols instead of Esc on fast rolls), try `PERMISSIVE_HOLD` first;
  the fallback is swapping the pair (Esc on 53, Tab on 43).
