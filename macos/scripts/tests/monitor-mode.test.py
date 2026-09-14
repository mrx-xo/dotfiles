"""Exercise monitor handoff without touching physical displays or Windows."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "monitor-mode.sh"


class WindowsSyncTest(unittest.TestCase):
    def run_handoff(self, ssh_body):
        with tempfile.TemporaryDirectory() as root:
            home = Path(root)
            state = home / ".local/state/monitor-mode"
            state.mkdir(parents=True)
            (state / "center").write_text("mac\n")
            (state / "right").write_text("pc\n")
            bindir = home / "bin"
            bindir.mkdir()
            for name, body in {
                "m1ddc": "echo 18",
                "osascript": "exit 0",
                "ssh": ssh_body,
            }.items():
                executable = bindir / name
                executable.write_text("#!/bin/bash\n" + body + "\n")
                executable.chmod(0o755)
            env = dict(os.environ, HOME=root,
                       PATH=str(bindir) + ":/usr/bin:/bin")
            result = subprocess.run(
                ["/bin/bash", str(SCRIPT), "4", "pc"], env=env,
                capture_output=True, text=True, timeout=5)
            completed = (home / "ssh-completed").exists()
            # Let an incorrectly detached stub finish before removing its HOME.
            import time
            time.sleep(0.4)
            return result, completed

    def test_handoff_waits_for_windows_request(self):
        result, completed = self.run_handoff(
            'sleep 0.2\ntouch "$HOME/ssh-completed"')
        self.assertEqual(result.returncode, 0)
        self.assertTrue(completed, "handoff exited before Windows request finished")

    def test_failed_windows_request_is_visible(self):
        result, _ = self.run_handoff('echo "connection failed" >&2\nexit 255')
        self.assertIn("Windows sync failed", result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
