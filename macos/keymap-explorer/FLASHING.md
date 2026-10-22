# Flashing the Keebio Iris SE

Verified on MrX on 2026-09-28 during the v1 flash. The hotdox76v2 runbook
this file replaced is in git history up to `c39eb8b`.

KOMAX (Keychron K0 Max) is flashed too, from Keychron's QMK fork; see
[KOMAX: flashing from Keychron's fork](#komax-flashing-from-keychrons-fork)
at the end.

## Facts

- QMK target `keebio/iris/rev8`, keymap `mrx` at
  `~/qmk_firmware/keyboards/keebio/iris/keymaps/mrx/`.
- RP2040: the bootloader is in ROM, so the board cannot be bricked. In
  bootloader mode it mounts as a drive named `RPI-RP2` and takes a `.uf2`.
- The halves link with a USB-C to USB-C cable (no TRRS). Each half has two
  USB-C ports, and either half can be the USB side.
- **Flash both halves with the same `.uf2`.** One half on mrx and one on
  factory firmware gives a dead keyboard: no typing, no key combos.

## The easy way

```bash
iris-flash
```

A gum walkthrough (`macos/scripts/iris-flash`): builds, asks which halves
and where the cable is, then per half waits for the cable, the bootloader
drive, the copy and the reconnect, and finishes with the home-row check.
Each result is logged to `~/.local/state/iris-flash.log`, and the start
screen shows the last flash of each half. The steps below are what it
automates.

`iris-flash --demo` walks the same screens with nothing built, copied or
logged: every wait is a two-second fake that succeeds.

## Enter the bootloader

Either of these, per half:

1. Double-tap the reset button through the hole in the bottom plate, fast
   (under half a second).
2. On mrx firmware: hold Space + Enter (System layer), tap `BOOT`.

On factory firmware the boot combo is Lower + R (left) or Raise + Del
(right).

## Flash

1. Build and wait for the drive (give it a long timeout; it waits for you):

   ```bash
   cd ~/qmk_firmware && timeout 600 qmk flash -kb keebio/iris/rev8 -km mrx
   ```

2. Put the USB-side half in the bootloader. The command copies the `.uf2`
   and the half reboots.
3. Move the USB cable to the other half, put it in the bootloader, and run
   the same command again.

A prebuilt `keebio_iris_rev8_mrx.uf2` lands in `~/qmk_firmware` after any
`qmk compile`; dragging it onto `RPI-RP2` works too.

## Troubleshooting

- **Mac does not see the board:** check the USB cable is actually plugged in
  before theorizing. It happened once.
- **Keyboard dead after a flash:** the other half is still on different
  firmware. Flash it too.
- **Is each half really flashed?** The half with the Mac cable runs the
  keymap for the whole board, so typing with the cable in one half says
  nothing about the other half. Test each: put the cable in a half and type
  the home row. `aoeuidhtns-` is mrx; `asdfghjkl;'` is factory. A raw HID
  interface proves nothing either, because factory VIA firmware has one too.
  (2026-09-29: the left half was still factory after "flashing both".)

## KOMAX: flashing from Keychron's fork

Written 2026-10-22 before the first flash; steps marked *unverified* get
confirmed on the bench and this note goes away. The old Launcher section
is in git history up to `cb63fe1`.

### Facts

- Not in mainline QMK. Source: `github.com/Keychron/qmk_firmware`, branch
  `2025q3`, checked out at `~/qmk_keychron` (separate from the Iris's
  `~/qmk_firmware`; local branch `mrx` carries the keymap and two small
  patches to `keyboards/keychron/common/`).
- Target `keychron/k0_max`, keymap `mrx` at
  `keyboards/keychron/k0_max/keymaps/mrx/`. STM32L432, `stm32-dfu`
  bootloader, output `keychron_k0_max_mrx.bin`.
- `VIA_ENABLE = no`: Launcher cannot see or change the keymap. The pad's
  USB id stays `0x3434:0x0A06`; the Keychron Link dongle is `0x3434:0xD030`.
- Bootmagic is matrix `[0, 1]` = **Esc** (not the knob). The `.bin` step
  needs `dfu-suffix` (`brew install dfu-util`).

### Build

```bash
cd ~/qmk_keychron && QMK_HOME=~/qmk_keychron qmk compile -kb keychron/k0_max -km mrx
```

`QMK_HOME` for that shell only, so the Iris tree is untouched.

### Flash

1. Put the mode switch on **cable** and plug the USB-C cable into POLLUX
   while holding **Esc** (bootmagic). *Unverified*: it should enumerate as
   `STM32 BOOTLOADER` (`dfu-util -l`). If not, unplug, hold Esc before the
   cable goes in and keep holding until it shows up.
2. Flash:

   ```bash
   cd ~/qmk_keychron && QMK_HOME=~/qmk_keychron qmk flash -kb keychron/k0_max -km mrx
   ```

   or, with the built file, `dfu-util -a 0 -d 0483:df11 -s 0x8000000:leave -D keychron_k0_max_mrx.bin`.
3. Check wired: M1 to M4, the Fn key and the knob press arm and fire
   (`skhd -o`, or the sketchybar armed indicator); numpad and knob turn
   stock.
4. Unplug the cable, switch to **2.4 GHz**, dongle in POLLUX: it should
   type through the dongle at once. If not, re-pair (next section).

### Re-pairing the dongle and lighting (the hidden Fn layer)

The stock Fn layer is still compiled in, behind a chord: hold the **knob
press** and **Enter** (#26) together (`COMBO_TERM` 80 ms). While held:

- `P2P4G` (#4, the Bksp position) re-pairs the dongle: hold it with the
  dongle plugged into the target machine.
- `UG_TOGG` (knob press), `UG_NEXT` / `UG_VALU` / `UG_HUEU` and friends set
  the lighting; the knob turn changes brightness. These write EEPROM, so
  they survive a power cycle. The night-lights message never does.

### Night lights on the bench

```bash
~/.dotfiles/macos/scripts/keyboard-lights off
```

Expect `komax: off` by cable. Then on the dongle: if it prints
`komax: no reply`, the closed dongle firmware does not forward host-to-pad
raw HID; record that in VERSIONS.md and accept cable-only (the pad's own
idle sleep darkens it overnight). Keys pressed while dark must not relight
it; `keyboard-lights on` brings the saved look back.
