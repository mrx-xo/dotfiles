#!/usr/bin/env python3
"""keymap-widget HID listener — Phase B of the live keymap widget.

Opens a QMK board's raw HID interface (usage page 0xFF60 / usage 0x61)
and relays the firmware's layer broadcasts ([0x4C, layer, 0...]) to stdout
as "L<n>" lines. Hammerspoon (keymap-widget.lua) spawns one per board and
forwards each line to that board's webview via __setLayer(n).

Usage: keymap-widget-hid.py [VID PID]   (hex or decimal; default: hotdox)
Boards emitting the 0x4C frame: hotdox76v2/keymaps/mrx (keymap.c),
work_louder/micro/keymaps/mrx (keymap.c — VIA build, broadcast rides
VIA's raw HID interface; non-0x4C frames are VIA traffic, dropped here).

Exits nonzero when the board is absent or a read fails (unplug/sleep);
the reconnect/backoff policy lives in Hammerspoon, not here.

Spec: ~/roaming/projects/keymap-explorer/live-keymap-widget-prd.md
"""

import sys

import hid

VID, PID = 0xAA96, 0xAAA9  # keyboards/hotdox76v2/keyboard.json
USAGE_PAGE, USAGE = 0xFF60, 0x61  # QMK raw HID
TAG = 0x4C  # 'L' — layer frames from the mrx keymaps; drop all others


def main():
    vid, pid = VID, PID
    if len(sys.argv) == 3:
        vid, pid = (int(a, 0) for a in sys.argv[1:3])
    path = next(
        (
            d["path"]
            for d in hid.enumerate(vid, pid)
            if d["usage_page"] == USAGE_PAGE and d["usage"] == USAGE
        ),
        None,
    )
    if path is None:
        print("no raw HID interface found (board unplugged?)", file=sys.stderr)
        return 1

    dev = hid.device()
    try:
        dev.open_path(path)
        while True:
            frame = dev.read(32)  # blocking
            if not frame:
                print("empty read (device detached?)", file=sys.stderr)
                return 1
            if frame[0] == TAG:
                print(f"L{frame[1]}", flush=True)
    except (OSError, IOError, ValueError) as e:
        print(f"HID error: {e}", file=sys.stderr)
        return 1
    finally:
        dev.close()


if __name__ == "__main__":
    sys.exit(main())
