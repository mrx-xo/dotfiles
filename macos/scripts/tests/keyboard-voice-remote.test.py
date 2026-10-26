#!/usr/bin/env python3
"""Verify the remote voice command boundary without SSH or microphone access."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "keyboard-voice-remote.sh"


class RemoteVoice(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name)
        self.config = self.home / ".config/keyboard-voice/ssh-host"
        self.config.parent.mkdir(parents=True)
        self.config.write_text("test-voice-host\n")
        bindir = self.home / "bin"
        bindir.mkdir()
        for name, body in {
            "ssh": 'printf "%s\\n" "$@" > "$HOME/ssh-args"; exit "${FAKE_SSH_EXIT:-0}"',
            "timeout": 'printf "%s\\n" "$1" > "$HOME/timeout"; shift; exec "$@"',
        }.items():
            path = bindir / name
            path.write_text("#!/bin/bash\n" + body + "\n")
            path.chmod(0o755)
        self.env = {**os.environ, "HOME": str(self.home),
                    "PATH": str(bindir) + ":/usr/bin:/bin"}

    def run_command(self, *args):
        return subprocess.run(["bash", str(SCRIPT), *args], env=self.env,
                              capture_output=True, text=True, timeout=3)

    def test_dispatch_is_fixed_noninteractive_and_time_bounded(self):
        result = self.run_command()
        self.assertEqual(result.returncode, 0, result.stderr)
        args = (self.home / "ssh-args").read_text().splitlines()
        self.assertIn("-n", args)
        self.assertIn("BatchMode=yes", args)
        self.assertIn("ConnectTimeout=3", args)
        self.assertEqual(args[-2:], ["test-voice-host",
            "MSYS_NO_PATHCONV=1 schtasks.exe /run /tn keyboard-voice-toggle"])
        self.assertEqual((self.home / "timeout").read_text().strip(), "8")

    def test_missing_host_fails_without_connecting(self):
        self.config.unlink()
        result = self.run_command()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("ssh-host", result.stderr)
        self.assertFalse((self.home / "ssh-args").exists())

    def test_host_cannot_supply_ssh_options_or_shell_commands(self):
        for host in ["-oProxyCommand=bad", "host;bad", "host\nother"]:
            with self.subTest(host=host):
                self.config.write_text(host)
                self.assertEqual(self.run_command().returncode, 2)
                self.assertFalse((self.home / "ssh-args").exists())

    def test_arbitrary_task_or_extra_arguments_are_rejected(self):
        self.assertEqual(self.run_command("other-task").returncode, 2)
        self.assertFalse((self.home / "ssh-args").exists())

    def test_ssh_failure_propagates_without_retry(self):
        self.env["FAKE_SSH_EXIT"] = "255"
        self.assertEqual(self.run_command().returncode, 255)


if __name__ == "__main__":
    unittest.main()
