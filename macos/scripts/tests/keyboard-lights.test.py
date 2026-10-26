#!/usr/bin/env python3
"""keyboard-lights off|on: unit tests with a fake `hid` module.

Run: python3 macos/scripts/tests/keyboard-lights.test.py -v
No keyboard is touched: `hid` is replaced in sys.modules before the script
is imported, so enumerate/open/write/read are all scripted here.
"""
import importlib.util
import io
import sys
import types
import unittest
from contextlib import redirect_stdout, redirect_stderr
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent.parent / "keyboard-lights"

IRIS = (0xCB10, 0x8256)
KOMAX_CABLE = (0x3434, 0x0A06)
KOMAX_DONGLE = (0x3434, 0xD030)
RAW = {"usage_page": 0xFF60, "usage": 0x61}
KBD = {"usage_page": 0x01, "usage": 0x06}


class FakeHid:
    """Stands in for the `hid` module: devices present, their replies, a log."""

    def __init__(self, present, reply=None):
        self.present = present            # list of (vid, pid)
        self.reply = reply or {}          # path -> bytes the board answers, or None for silence
        self.writes = []                  # (path, bytes)
        self.exclusive_calls = []
        self.opened = []
        fake = self
        hid = types.ModuleType("hid")
        hid.__file__ = "/fake/hid.so"

        def enumerate(vid=0, pid=0):
            out = []
            for v, p in fake.present:
                if (vid and v != vid) or (pid and p != pid):
                    continue
                for usage in (KBD, RAW):
                    out.append(dict(vendor_id=v, product_id=p, path=f"{v:04x}:{p:04x}:{usage['usage']:02x}".encode(), **usage))
            return out

        class device:
            def __init__(self):
                self.path = None
            def open_path(self, path):
                self.path = path
                fake.opened.append(path)
            def set_nonblocking(self, flag):
                pass
            def write(self, data):
                fake.writes.append((self.path, bytes(data)))
                return len(data)
            def read(self, size, timeout_ms=0):
                r = fake.reply.get(self.path, b"")
                return list(r[:size]) if r else []
            def close(self):
                pass

        hid.enumerate = enumerate
        hid.device = device
        self.module = hid


def load(fake):
    sys.modules["hid"] = fake.module
    spec = importlib.util.spec_from_loader("keyboard_lights", loader=None, origin=str(SCRIPT))
    mod = importlib.util.module_from_spec(spec)
    exec(compile(SCRIPT.read_text(), str(SCRIPT), "exec"), mod.__dict__)
    return mod


def run(fake, *argv):
    mod = load(fake)
    out, err = io.StringIO(), io.StringIO()
    with redirect_stdout(out), redirect_stderr(err):
        code = mod.main(list(argv))
    return code, out.getvalue(), err.getvalue()


def raw_path(vid, pid):
    return f"{vid:04x}:{pid:04x}:61".encode()


def reply(cmd):
    return bytes([0x4E, cmd]) + bytes(30)


class OffOn(unittest.TestCase):
    def test_off_sends_frame_to_each_board(self):
        fake = FakeHid([IRIS, KOMAX_DONGLE], {raw_path(*IRIS): reply(0), raw_path(*KOMAX_DONGLE): reply(0)})
        code, out, err = run(fake, "off")
        self.assertEqual(code, 0, err)
        self.assertEqual(sorted(p for p, _ in fake.writes), sorted([raw_path(*IRIS), raw_path(*KOMAX_DONGLE)]))
        for _, frame in fake.writes:
            # hidapi wants the report id first; QMK raw HID has none, so 0x00 + 32 bytes.
            self.assertEqual(len(frame), 33)
            self.assertEqual(frame[0], 0x00)
            self.assertEqual(frame[1:3], bytes([0x4E, 0x00]))
            self.assertEqual(frame[3:], bytes(30))
        self.assertEqual(out.splitlines(), ["iris: off", "komax: off"])

    def test_on_sends_one(self):
        fake = FakeHid([IRIS], {raw_path(*IRIS): reply(1)})
        code, out, _ = run(fake, "on")
        self.assertEqual(code, 0)
        self.assertEqual(fake.writes[0][1][1:3], bytes([0x4E, 0x01]))
        self.assertEqual(out.splitlines(), ["iris: on", "komax: not connected"])

    def test_missing_board_is_reported_not_fatal(self):
        fake = FakeHid([IRIS], {raw_path(*IRIS): reply(0)})
        code, out, _ = run(fake, "off")
        self.assertEqual(code, 0)
        self.assertIn("komax: not connected", out)
        self.assertIn("iris: off", out)

    def test_no_board_at_all_exits_0(self):
        code, out, _ = run(FakeHid([]), "off")
        self.assertEqual(code, 0)
        self.assertEqual(out.splitlines(), ["iris: not connected", "komax: not connected"])

    def test_unconfirmed_board_exits_1(self):
        fake = FakeHid([IRIS, KOMAX_CABLE], {raw_path(*IRIS): reply(0)})  # KOMAX never replies
        code, out, _ = run(fake, "off")
        self.assertEqual(code, 1)
        self.assertIn("iris: off", out)
        self.assertIn("komax: no reply", out)

    def test_reply_reports_the_boards_actual_state(self):
        """A board whose lighting was already off answers 'on' with 0: that is
        a confirmation (the spec says it stays off), reported as it is."""
        fake = FakeHid([IRIS], {raw_path(*IRIS): reply(0)})
        code, out, _ = run(fake, "on")
        self.assertEqual(code, 0)
        self.assertEqual(out.splitlines(), ["iris: off", "komax: not connected"])

    def test_silence_is_unconfirmed(self):
        fake = FakeHid([IRIS], {raw_path(*IRIS): None})
        code, out, _ = run(fake, "on")
        self.assertEqual(code, 1)
        self.assertIn("iris: no reply", out)

    def test_other_tags_are_skipped_until_the_reply(self):
        fake = FakeHid([IRIS], {raw_path(*IRIS): bytes([0x4C, 0x02]) + bytes(30)})  # only layer frames
        code, out, _ = run(fake, "off")
        self.assertEqual(code, 1)
        self.assertIn("iris: no reply", out)

    def test_bad_usage_exits_2(self):
        for argv in ([], ["dim"], ["off", "on"]):
            with self.subTest(argv=argv):
                code, _, err = run(FakeHid([IRIS]), *argv)
                self.assertEqual(code, 2)
                self.assertIn("usage", err)

    def test_opens_non_exclusive(self):
        """The wallpaper widget holds the Iris open; we must not seize it.

        hidapi seizes by default on macOS; the fix is hid_darwin_set_open_exclusive(0)
        on the bundled library (reached through ctypes) before the first open."""
        import ctypes
        fake = FakeHid([IRIS], {raw_path(*IRIS): reply(0)})
        events = []

        class Lib:
            def hid_darwin_set_open_exclusive(self, flag):
                events.append(("exclusive", flag))

        real = ctypes.CDLL
        ctypes.CDLL = lambda name: (events.append(("cdll", name)), Lib())[1]
        try:
            code, _, _ = run(fake, "off")
        finally:
            ctypes.CDLL = real
        self.assertEqual(code, 0)
        self.assertIn(("cdll", "/fake/hid.so"), events)
        self.assertIn(("exclusive", 0), events)
        self.assertEqual(fake.opened, [raw_path(*IRIS)])

    def test_survives_hidapi_without_the_exclusive_call(self):
        import ctypes
        fake = FakeHid([IRIS], {raw_path(*IRIS): reply(0)})
        real = ctypes.CDLL
        ctypes.CDLL = lambda name: object()
        try:
            code, out, _ = run(fake, "off")
        finally:
            ctypes.CDLL = real
        self.assertEqual(code, 0)
        self.assertIn("iris: off", out)

    def test_komax_cable_and_dongle_count_once(self):
        fake = FakeHid([KOMAX_CABLE, KOMAX_DONGLE], {raw_path(*KOMAX_CABLE): reply(0), raw_path(*KOMAX_DONGLE): reply(0)})
        code, out, _ = run(fake, "off")
        self.assertEqual(code, 0)
        self.assertEqual([l for l in out.splitlines() if l.startswith("komax")], ["komax: off"])


if __name__ == "__main__":
    unittest.main()
