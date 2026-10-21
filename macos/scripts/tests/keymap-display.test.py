"""Exercise skhd routing without moving real windows or displays."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "keymap-display.sh"


class DisplayRoutingTest(unittest.TestCase):
    def run_route(self, reply, index="3", hs_status="0"):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            log = root / "calls"
            for name, text in {
                "hs": '#!/bin/sh\n[ "$1" = "-a" ] || exit 64\nprintf "%s\\n" "$HS_REPLY"\nexit "$HS_STATUS"\n',
                "yabai": '#!/bin/sh\nprintf "%s\\n" "$*" >> "$CALLS"\n',
            }.items():
                program = root / name
                program.write_text(text)
                program.chmod(0o755)
            env = dict(os.environ, PATH=f"{root}:/usr/bin:/bin", CALLS=str(log),
                       HS_REPLY=reply, HS_STATUS=hs_status)
            result = subprocess.run(["/bin/bash", str(SCRIPT), index], env=env,
                                    capture_output=True, text=True)
            return result.returncode, log.read_text().splitlines() if log.exists() else []

    def test_overlay_moves_without_moving_underlying_window(self):
        self.assertEqual(self.run_route("-- Loading extension: json\nkeymap:moved"),
                         (0, ["-m display --focus 3"]))

    def test_closed_overlay_preserves_move_and_follow(self):
        self.assertEqual(self.run_route("keymap:inactive"),
                         (0, ["-m window --display 3", "-m display --focus 3"]))

    def test_unavailable_monitor_does_not_move_underlying_window(self):
        self.assertEqual(self.run_route("keymap:unavailable"), (0, []))

    def test_hammerspoon_unavailable_preserves_normal_shortcut(self):
        self.assertEqual(self.run_route("", hs_status="75"),
                         (0, ["-m window --display 3", "-m display --focus 3"]))

    def test_ipc_failure_does_not_move_an_uncertain_target(self):
        status, calls = self.run_route("", hs_status="69")
        self.assertNotEqual(status, 0)
        self.assertEqual(calls, [])

    def test_missing_routing_reply_does_not_move_an_uncertain_target(self):
        status, calls = self.run_route("-- Loading extension: json")
        self.assertNotEqual(status, 0)
        self.assertEqual(calls, [])

    def test_invalid_index_is_rejected(self):
        status, calls = self.run_route("keymap:inactive", "3; bad")
        self.assertNotEqual(status, 0)
        self.assertEqual(calls, [])


if __name__ == "__main__":
    unittest.main()
