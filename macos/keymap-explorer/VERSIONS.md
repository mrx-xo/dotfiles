# Layout version ledger

One integer per **flashed** layout, forever incrementing. "What version is on
the board?" is answered here and in the explorer's eyebrow and footer.

A flash promotes a draft: it gets a keymap.c reference and a flash date here,
the old current is marked retired, and the explorer's `cur` maps are updated
to match `keymap.c`.

The hotdox76v2 (v1-v4 draft) and Creator Micro (v1-v5 draft) ledgers are in
git history up to `c39eb8b`. Both boards died on 2026-08-03.

KOMAX is flashed like the Iris since 2026-10-22, from a checkout of
Keychron's QMK fork (`~/qmk_keychron`, branch `2025q3`, keymap on local
branch `mrx`). Its entries cite that checkout's commit.

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

### v2: retired 2026-10-22 (both halves flashed 2026-09-29)
- keymap: `qmk_firmware` commit `aa41906e08` (`keyboards/keebio/iris/keymaps/mrx/`)
- v1 layout plus the raw HID layer broadcast
  (`[0x4C, layer]`, master half only) for the wallpaper widget.
  `RAW_ENABLE = yes`.
- Tab comes back to the thumb (2026-09-29): #53 (right inner thumb)
  Esc -> `KC_TAB`; #43 (inner right) `MO(1)` -> `LT(1, KC_ESC)`, tap Esc,
  hold Symbols. Esc also stays on the #0 corner. If the #43 Esc misfires in
  Evil (Symbols instead of Esc on fast rolls), try `PERMISSIVE_HOLD` first;
  the fallback is swapping the pair (Esc on 53, Tab on 43).

### v3: on board, flashed 2026-10-22 (both halves)
- keymap: `qmk_firmware` commit `38e72183ea` (`keyboards/keebio/iris/keymaps/mrx/`),
  `keebio_iris_rev8_mrx.uf2`. Everything below is in `keymap.c` now; the
  explorer cross-check (`pro*` arrays against `keymap.c`, 223 keycodes) passed.
- Night lights: `raw_hid_receive` answers tag `0x4E` (off saves the
  configured RGB state in RAM and disables without EEPROM; on restores;
  reply `[0x4E, lit]`). `night_lights.c` is host-tested; the Game beacon
  stays off while dark. The `[0x4C, layer]` broadcast is unchanged.
- `rules.mk`: `MOUSEKEY_ENABLE = yes`, `COMBO_ENABLE = yes`, `SRC += night_lights.c`.
- Right half: recovered with a direct UF2 copy after the guided flasher's
  spinner prevented its copy; v3 raw-HID reply and typing confirmed.
  Left half: fixed `iris-flash` completed and verified the home row.
- Lighting verified on both halves with the wallpaper widget running:
  off twice, dark during typing, on restores the same look, and a power
  cycle while dark restores the saved look without an on command.
- Remaining physical acceptance: Nav row, direct `?`, knob scroll,
  Emacs door and a Hyper command, and CleanShot area capture.

#### v3 draft history (explorer only until 2026-10-22)
- **Before flashing (found 2026-10-22):** `keymap.c` is still v2, so v3 has
  to be written into it first. Both blockers cleared 2026-10-22:
  agent-workspace moved from Hyper+B to Meh+B, freeing B for buffers; and
  the six Emacs letters are bound in `emacs.org` as a hybrid (q quick-ask,
  x M-x; c m v w open the SPC Agent Shell / bookmarks / vterm / window
  menu). ✦w is now the window menu, not perspective. `rules.mk`
  also needs `MOUSEKEY_ENABLE = yes` (knob scroll) and `COMBO_ENABLE = yes`
  (the door). Unverified: that Cmd+Shift+4 starts CleanShot X area capture.
- 2026-10-19: Nav #1-#5 swap with #13-#17. Agenda, Recent, Layout,
  Bookmarks and Scratch (in that order) move to the top letter row; Home / End / PgUp / PgDn move to
  the number row (explorer only).
- 2026-10-08: System #34 (Base `S` position) -> `LSG(KC_4)`, `Shot · Area`.
  Hold Space + Enter, tap S to send Cmd+Shift+4 for CleanShot X area
  selection via its existing shortcut (explorer only).
- 2026-10-07: Symbols #23 (Base `/` position) -> `KC_QUES`, direct `?`
  without Shift (explorer only).
- Nav #5 (last blank on the daily-driver row) -> `LCG(KC_B)`, the
  Hammerspoon bookmark popup (`bookmark-popup.lua`, Cmd+Ctrl+B).
- Emacs layer (5) ported from the hotdox v4 d1 draft (`8457210`): each key
  sends `HYPR(letter)` on its own Dvorak position. Live in `emacs.org`:
  i b g s r p o d. Bound 2026-10-22 (hybrid): q x direct; c m v w open
  their SPC menus.
  F H J K L E A T blank (yabai Hyper binds).
- Door: combo of both inner thumbs (#52 Bksp + #53 Tab) -> `OSL(5)`.
  Needs `COMBO_ENABLE = yes`. Watch Ctrl+Tab (hold Bksp, tap Tab) against
  `COMBO_TERM`.
- Knob on Base turns a mouse wheel (`MS_WHLU` / `MS_WHLD`, needs
  `MOUSEKEY_ENABLE = yes`); held Shift / Cmd / Alt give horizontal / zoom /
  fast scroll from macOS. Volume moves to the Symbols turn; Prev/Next drop.

## Ledger: KOMAX (Keychron K0 Max, keychron/k0_max)

### Stock: retired 2026-10-22 (on the pad since 2026-10-19)
- Keychron `keymaps/default` (qmk_firmware branch `2025q3`), never touched in
  Launcher. Retired by firmware v1 (compiled keymap).
- Base: knob press Mute, turn volume; Esc Del Tab Bksp; M1 to M4 empty macro
  slots (`MC_1` to `MC_4`, send nothing); numpad; **Fn** bottom-left
  (`MO(1)`).
- Fn: Bluetooth slots 1 to 3, 2.4 GHz pairing, RGB, Prev / Play / Next; knob
  turns brightness.
- Host-side, not on the pad: `pad-fluid.ahk` on NEMESIS (2026-10-20) maps the
  numpad `*` to F20 for Fluid dictation while the pad sat there. The desk
  grammar plan retires it.

### v1: on the pad, flashed 2026-10-22
- keymap: `~/qmk_keychron` commit `3427816` (`keyboards/keychron/k0_max/keymaps/mrx/`),
  `keychron_k0_max_mrx.bin`, `VIA_ENABLE = no`, `RAW_ENABLE = yes`,
  `COMBO_ENABLE = yes`. Two small patches to the fork's common code ride on
  the same branch (weak `kc_raw_hid_rx_user` and `indicator_enable_allowed`
  hooks).
- Night lights verified by cable and through the 2.4 GHz dongle: both
  receive commands and reply, repeated off is safe, typing stays dark,
  and on restores the same colour, brightness and effect. Longer idle/wake
  behavior is not yet physically verified.
- The desk grammar from `docs/active/plans/2026-10-21-komax-desk-grammar.md`:
  M1 F13 ROMULUS, M2 F14 REMUS, M3 F15 NYX (screens, arm); M4 F16 POLLUX,
  M5 F17 NEMESIS, knob press F19 WORK (machines, fire).
- Numpad, Esc/Del/Tab/Bksp and the knob turn stay stock.
- **NEMESIS takes the former Fn position (#23)**. The physical cap is
  printed **M5**. The Fn layer remains behind the knob+Enter combo.
- Daily connection: the **2.4 GHz dongle on POLLUX** (decided 2026-10-22);
  the USB-C cable is for flashing. Move the dongle off NEMESIS first.
- The Fn layer stays in the firmware behind a hidden door: hold the knob
  press and Enter together (`COMBO_TERM` 80 ms), then `P2P4G` (#4) re-pairs
  the dongle and the `UG_*` keys set the lighting.
- Keys: M1 `KC_F13`, M2 `KC_F14`, M3 `KC_F15`, M4 `KC_F16`, #23 `KC_F17`,
  knob press `KC_F19`; everything else stock Base.
- Bootloader entry and USB flash verified: hold the physical **circle (○)**
  key immediately right of the knob while plugging in; `dfu-util` detects
  `0483:df11`. Firmware downloaded successfully and the pad reconnected.
- Remaining physical acceptance: six desk-grammar keys, numpad and knob
  behavior, hidden Fn/re-pair controls, and the voice routine. The current
  explorer map now reflects the flashed firmware.
