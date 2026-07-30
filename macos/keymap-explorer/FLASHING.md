# Flashing the hotdox76v2 — verified runbook

Everything here was verified on MrX on 2026-07-24 by inspecting
`~/qmk_firmware` and the board sources, running `qmk doctor`, and
test-compiling. No folklore.

## Verified facts

- **Source of truth**: `~/qmk_firmware` @ `8eb6039` ("feat: newest keymap
  that actually works") — the exact commit the currently-running firmware
  came from. Keymap: `keyboards/hotdox76v2/keymaps/mrx/`.
- **Hardware**: ATmega32u4 ×2 — one per half, split over serial (D2), both
  halves run QMK. Bootloader: **atmel-dfu** → flash tool is
  `dfu-programmer`.
- **Toolchain**: avr-gcc 8.5.0 works; build verified end-to-end today
  (28206/28672 bytes). `dfu-programmer` was **missing** until 2026-07-24
  (installed via brew) — CLI flashing could never have worked before that,
  which is likely a chunk of the historical flashing pain. Past flashes
  went through **QMK Toolbox.app** (installed, still a valid fallback).
- **No handedness config** → QMK default `MASTER_LEFT`: USB plugs into the
  **left** half.

## The procedure

```bash
cd ~/qmk_firmware
qmk flash -kb hotdox76v2 -km mrx     # builds, then waits for bootloader
# → press the reset button on the back of the left (USB) half
# → dfu-programmer erases, flashes, resets automatically
```

GUI alternative: QMK Toolbox, open `~/qmk_firmware/hotdox76v2_mrx.hex`,
MCU `atmega32u4`, enter bootloader (reset button), Flash.

### Entering the bootloader — what actually works on THIS board

1. **Physical reset button** on the back of the PCB — the only reliable
   way today.
2. **`QK_BOOT` keycode** — exists on layer 3 but layer 3 has no activator
   in the current keymap; becomes real once the new layout (tri-layer)
   lands.
3. **Bootmagic (hold key while plugging in) DOES NOT WORK** — the QMK
   readme says "hold Esc" but bootmagic fires on matrix (0,0), and this
   board has **no key at matrix (0,0)** (left-half rows are inverted:
   row 0 is the thumb cluster, col 0 empty — verified in keyboard.json;
   no `BOOTMAGIC_ROW/COLUMN` override exists). The readme is wrong for
   this hardware.

## EEPROM after flashing — DEFUSED (updated 2026-07-27)

Historical hazard: VIA's dynamic keymap lives in EEPROM and **overrides
the compiled defaults**; flashing does not touch it, so the board could
come up running the OLD layout. **Decision 2026-07-27: the new firmware
ships `VIA_ENABLE = no`** — no dynamic keymap, the compiled keymap is the
only keymap, and this whole class of problem disappears.

One-time on the transition flash: still run QMK Toolbox → Tools → Clear
EEPROM to wipe stale VIA data and let eeconfig re-init clean. After that,
no post-flash ritual exists. (VIA app "Reset Keymap" stops being an
option once VIA is gone.)

## Size budget — the 98% problem

ATmega32u4 usable flash: 28672 bytes. Verified by test-compiles today:

- Current build (`MOUSEKEY=yes, EXTRAKEY=no`): 28206 bytes, **466 free** —
  no room for the planned features as-is.
- Future build (`MOUSEKEY=no, EXTRAKEY=yes, CAPS_WORD=yes`): 27772 bytes,
  **900 free**. Killing mousekey (the wheel keys are being removed from
  the layout anyway) pays for media keys + Caps Word with room left.
- Still to add within those 900 bytes: tri-layer (~100 B), Game-layer RGB
  indicator (~200 B), Phase B raw-HID layer broadcast (~150 B). Tight but
  plausible; the compile size check is the gate.
- Headroom update 2026-07-27: `VIA_ENABLE = no` (decided) frees ~2KB on
  top of the numbers above (both test-compiles had VIA on), minus a
  little back for `RAW_ENABLE = yes` standing alone. Comfortable —
  re-verify with a test compile once the new keymap.c exists.
- If it overflows: `#undef` more rgb_matrix animations in keymap config.h,
  or NKRO off.

## Dry test — prove the chain without flashing anything

Read-only end-to-end test of macOS → USB → bootloader → flasher. Nothing
is written; unplug/replug always returns the board to normal.

```bash
# 1. plug the LEFT half into the Mac, confirm it enumerates:
ioreg -r -c IOUSBHostDevice -l | grep '"USB Product Name"'   # expect hotdox76

# 2. press the reset button on the back of the LEFT half, re-check:
ioreg -r -c IOUSBHostDevice -l | grep '"USB Product Name"'   # expect ATm32U4DFU

# 3. the actual proof:
dfu-programmer atmega32u4 get bootloader-version             # prints a version

# 4. back to normal firmware (nothing was flashed):
dfu-programmer atmega32u4 launch      # or just unplug/replug
```

Both halves have a button on the back but only one is labeled "reset"
(hardware revisions vary). The one that matters for keymap flashing is the
**left** half's — it resets the master MCU.

**Dry test PASSED 2026-07-24 17:56.** Button press → `ATm32U4DFU`
enumerated in 2s → `get bootloader-version` answered (0x00) →
`launch` rebooted to normal firmware without unplugging. Worked through
the 20-in-1 dock + hubs — no direct connection required.

**Confirmed 2026-07-24 18:00: the LEFT half's button enters DFU.**
Tested deliberately (only that button pressed): keyboard-gone → DFU in
~1s. This is the button for all keymap flashing.

## THE FLASH HAPPENED — 2026-07-27

`qmk flash -kb hotdox76v2 -km mrx` + left-half reset button: erased,
programmed 26210 bytes (91.5%), validated, auto-reset, re-enumerated as
`hotdox76`. Typing on the new layout same minute. 2462 bytes free.

## v3 FLASH — 2026-07-29

Same procedure, boring in the best way: `qmk flash` + left reset button →
erased, programmed 26210 bytes (91.52%), validated, re-enumerated as
`hotdox76`. keymap.c commit `c6b22e1` (criss-cross Hyper/Meh, firmware
tab switching, Tab on #58/#59). No EEPROM ritual (VIA long gone), no
right-half reflash needed (no RGB/OLED changes). skhd ✦,/✦. tab binds
retired the same hour.

## keyboard.json lies about the right thumb talls (found 2026-07-27)

The board's `keyboard.json` draws the two right 2u thumb keys crossed:
it claims arg 74 (`R52`) is the outer tall (x=11) and arg 75 (`R53`) the
inner (x=10). **Physical truth is the opposite** — proven by keypress
after the flash: the outer tall registered Enter (arg 75). Consistent
with mirror symmetry: on the left half the JSON puts `L53` outer /
`L52` inner, so `R53` should mirror to outer; the right-half coords are
the one spot the JSON breaks its own symmetry. Only those two keys are
affected (all other thumb/alpha coords mirror cleanly).

Consequences:
- **The flashed firmware is physically ideal, no change needed**: Enter
  stayed on its lifelong outer key (gaining the Nav hold), Esc replaced
  Tab on the inner tall — the literal walk intent.
- The explorer/widget GEO inherited the JSON's swap and drew those two
  keys crossed through every sign-off; fixed in `index.html` 2026-07-27
  (draws physical reality, not the JSON).

## Post-flash aftermath — the two remaining physical steps (2026-07-28)

### 1. One-time EEPROM clear — now a keypress

The System layer is reachable since the flash and `EE_CLR` lives on it
(#16). Hold **Space + Enter** (tri-layer) and tap **EE Clr**. That
invalidates eeconfig; the next boot re-inits clean — the old QMK Toolbox
ritual collapses into one chord. Notes: RGB prefs reset to defaults;
stale VIA bytes may physically linger in EEPROM but nothing ever reads
them (`VIA_ENABLE = no`). If you want them literally zeroed, QMK Toolbox
→ Tools → Clear EEPROM still works.

### 2. Right-half flash (Game RGB / OLED sync)

Keymap logic runs on the master (left) half, so the board already
*behaves* correctly on the new layout; the right half needs the same hex
only for split-synced extras (solid-red Game RGB on its LEDs, OLED).

1. Unplug USB from the left half and plug it into the **right** half
   (leave the interconnect cable alone — just don't hot-plug it).
2. Press the reset button on the back of the right half; confirm:
   `ioreg -r -c IOUSBHostDevice -l | grep '"USB Product Name"'` →
   expect `ATm32U4DFU`.
3. Flash the already-built hex (no rebuild needed):
   ```bash
   cd ~/qmk_firmware
   dfu-programmer atmega32u4 erase --force
   dfu-programmer atmega32u4 flash hotdox76v2_mrx.hex
   dfu-programmer atmega32u4 launch
   ```
   (`qmk flash -kb hotdox76v2 -km mrx` also works — it just rebuilds
   first.)
4. Move USB back to the left half. Verify: System layer → `TG(4)` Game →
   both halves go solid red.

## Open items (the honest few %)

- [x] ~~EEPROM fit for 5 layers~~ MOOT 2026-07-27: `VIA_ENABLE = no`
      means no dynamic keymap in EEPROM at all — nothing to fit.
- [x] ~~The final proof is the flash itself~~ **FLASHED 2026-07-27**,
      typing on the new layout.
- [x] EEPROM clear keypress — DONE 2026-07-28.
- [x] Right-half flash — DONE 2026-07-28 (26240 bytes validated, Game RGB
      solid red on both halves confirmed). **Nothing left open.**
