#!/usr/bin/env python3
"""State-to-bar mapping for plugins/emacs-status.sh, against a fake sketchybar."""

import os
import pathlib
import subprocess
import tempfile
import time
import unittest

PLUGIN = pathlib.Path(__file__).parents[1] / "plugins" / "emacs-status.sh"


class EmacsStatusPluginTest(unittest.TestCase):
    def setUp(self):
        self.tmp = pathlib.Path(tempfile.mkdtemp())
        self.log = self.tmp / "calls"
        fake = self.tmp / "bin" / "sketchybar"
        fake.parent.mkdir()
        fake.write_text(f'#!/bin/sh\nprintf "%s\\n" "$*" >> "{self.log}"\n')
        fake.chmod(0o755)
        self.env = {
            "PATH": f"{fake.parent}:/usr/bin:/bin",
            "NAME": "emacs_status",
            "EMACS_STATUS_STATE_FILE": str(self.tmp / "state"),
            "EMACS_STATUS_SUMMARY": str(self.tmp / "summary.last"),
            "EMACS_STATUS_ALIVE_CMD": "true",
            "EMACS_STATUS_FLASH_SECONDS": "0.2",
        }

    def run_plugin(self, **env):
        subprocess.run(["bash", str(PLUGIN)], env={**self.env, **env}, check=True)

    def calls(self):
        return self.log.read_text() if self.log.exists() else ""

    def state(self):
        return (self.tmp / "state").read_text().strip()

    def test_booting_shows_the_label_in_yellow(self):
        self.run_plugin(SENDER="emacs_status_update", EMACS_STATUS_STATE="booting",
                        EMACS_STATUS_LABEL="devouring magit · 34/120 · 18s")
        self.assertIn("label.color=0xFFfabd2f label=devouring magit · 34/120 · 18s", self.calls())
        self.assertEqual(self.state(), "booting")

    def test_ready_flashes_green_then_hides(self):
        self.run_plugin(SENDER="emacs_status_update", EMACS_STATUS_STATE="ready",
                        EMACS_STATUS_LABEL="ready in 42s")
        self.assertIn("label.color=0xFFb8bb26 label=ready in 42s", self.calls())
        time.sleep(0.6)
        self.assertTrue(self.calls().rstrip().endswith("label.drawing=off"))
        self.assertEqual(self.state(), "idle")

    def test_health_check_marks_a_dead_daemon_down_and_a_live_one_quiet(self):
        self.run_plugin(SENDER="routine", EMACS_STATUS_ALIVE_CMD="false")
        self.assertIn("label=✗", self.calls())
        self.assertEqual(self.state(), "down")
        self.run_plugin(SENDER="routine")
        self.assertEqual(self.state(), "idle")

    def test_notready_survives_the_health_check(self):
        self.run_plugin(SENDER="emacs_status_update", EMACS_STATUS_STATE="notready",
                        EMACS_STATUS_LABEL="not ready after 120s")
        self.run_plugin(SENDER="routine", EMACS_STATUS_ALIVE_CMD="false")
        self.assertEqual(self.state(), "notready")

    def test_click_fills_the_popup_from_the_boot_summary(self):
        (self.tmp / "summary.last").write_text(
            "EMACS_BOOT_TOTAL=42\nEMACS_BOOT_INIT=1\nEMACS_BOOT_PACKAGES=41\n"
            "EMACS_BOOT_SLOWEST='ytr 20s, magit 6s'\n"
            "EMACS_BOOT_AT='Fri 12:00'\nEMACS_BOOT_PID=123\n")
        self.run_plugin(SENDER="mouse.clicked")
        calls = self.calls()
        self.assertIn("label=last boot 42s", calls)
        self.assertIn("label=init 1s · packages 41s", calls)
        self.assertIn("label=slowest: ytr 20s, magit 6s", calls)
        self.assertIn("label=at Fri 12:00 · pid 123", calls)
        self.assertIn("popup.drawing=toggle", calls)


if __name__ == "__main__":
    unittest.main()
