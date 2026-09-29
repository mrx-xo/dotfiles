# Flashing the Keebio Iris SE

Verified on MrX on 2026-09-28 during the v1 flash. The hotdox76v2 runbook
this file replaced is in git history up to `c39eb8b`.

## Facts

- QMK target `keebio/iris/rev8`, keymap `mrx` at
  `~/qmk_firmware/keyboards/keebio/iris/keymaps/mrx/`.
- RP2040: the bootloader is in ROM, so the board cannot be bricked. In
  bootloader mode it mounts as a drive named `RPI-RP2` and takes a `.uf2`.
- The halves link with a USB-C to USB-C cable (no TRRS). Each half has two
  USB-C ports, and either half can be the USB side.
- **Flash both halves with the same `.uf2`.** One half on mrx and one on
  factory firmware gives a dead keyboard: no typing, no key combos.

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
