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
            (state / "romulus").write_text("pollux\n")
            (state / "remus").write_text("nemesis\n")
            bindir = home / "bin"
            bindir.mkdir()
            for name, body in {
                "betterdisplaycli": "echo 4370",
                "displayplacer": 'echo "Persistent screen id: 0CDDE5CC-F566-4B56-85FD-48B8EA229946"',
                "osascript": "exit 0",
                "ssh": ssh_body,
            }.items():
                executable = bindir / name
                executable.write_text("#!/bin/bash\n" + body + "\n")
                executable.chmod(0o755)
            env = dict(os.environ, HOME=root,
                       PATH=str(bindir) + ":/usr/bin:/bin")
            result = subprocess.run(
                ["/bin/bash", str(SCRIPT), "remus", "nemesis"], env=env,
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


class ClaimTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.home = Path(self.tmp.name)
        self.state = self.home / ".local/state/monitor-mode"
        self.state.mkdir(parents=True)
        (self.state / "romulus").write_text("pollux\n")
        (self.state / "remus").write_text("nemesis\n")
        bindir = self.home / "bin"
        bindir.mkdir()
        for name, body in {
            "betterdisplaycli": "echo 4370",
            "displayplacer": 'echo "Persistent screen id: 0CDDE5CC-F566-4B56-85FD-48B8EA229946"',
            "osascript": "exit 0",
            "ssh": "exit 0",
            "yabai": "echo '[]'",
        }.items():
            exe = bindir / name
            exe.write_text("#!/bin/bash\n" + body + "\n")
            exe.chmod(0o755)
        self.env = dict(os.environ, HOME=self.tmp.name, MONITOR_MODE_LOCK_TRIES="2",
                        PATH=str(bindir) + ":/usr/bin:/bin")

    def tearDown(self):
        self.tmp.cleanup()

    def run_mm(self, *args):
        return subprocess.run(["/bin/bash", str(SCRIPT), *args], env=self.env,
                              capture_output=True, text=True, timeout=20)

    def test_claim_switches_and_remembers_previous_machine(self):
        r = self.run_mm("claim", "remus", "pollux", "pollux")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout.strip().splitlines()[-1], "ok nemesis")
        self.assertEqual((self.state / "remus").read_text().strip(), "pollux")
        claim = (self.state / "claims/remus").read_text()
        self.assertIn("holder=pollux", claim)
        self.assertIn("restore=nemesis", claim)

    def test_second_holder_is_refused(self):
        self.run_mm("claim", "remus", "pollux", "pollux")
        r = self.run_mm("claim", "remus", "nemesis", "nemesis")
        self.assertEqual(r.returncode, 3)
        self.assertEqual(r.stdout.strip(), "busy pollux")
        self.assertEqual((self.state / "remus").read_text().strip(), "pollux")

    def test_release_restores_previous_machine(self):
        self.run_mm("claim", "remus", "pollux", "pollux")
        r = self.run_mm("release", "remus", "pollux")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout.strip().splitlines()[-1], "restored nemesis")
        self.assertEqual((self.state / "remus").read_text().strip(), "nemesis")
        self.assertFalse((self.state / "claims/remus").exists())

    def test_release_leaves_a_manual_change_alone(self):
        self.run_mm("claim", "remus", "pollux", "pollux")
        (self.state / "remus").write_text("work\n")
        r = self.run_mm("release", "remus", "pollux")
        self.assertEqual(r.stdout.strip().splitlines()[-1], "left work")
        self.assertEqual((self.state / "remus").read_text().strip(), "work")
        self.assertFalse((self.state / "claims/remus").exists())

    def test_release_by_wrong_holder_keeps_the_claim(self):
        self.run_mm("claim", "remus", "pollux", "pollux")
        r = self.run_mm("release", "remus", "nemesis")
        self.assertEqual(r.returncode, 3)
        self.assertTrue((self.state / "claims/remus").exists())

    def test_json_reports_machine_and_holder(self):
        self.run_mm("claim", "remus", "pollux", "pollux")
        r = self.run_mm("json")
        import json
        data = json.loads(r.stdout)
        self.assertEqual(data["remus"], {"machine": "pollux", "claimedBy": "pollux"})
        self.assertEqual(data["romulus"]["claimedBy"], "")

    def test_live_lock_makes_a_second_run_wait_then_fail(self):
        holder = subprocess.Popen(["sleep", "30"])
        try:
            lock = self.state / "lock.d"
            lock.mkdir()
            (lock / "pid").write_text(str(holder.pid))
            r = self.run_mm("remus", "pollux")
            self.assertEqual(r.returncode, 1)
            self.assertIn("busy", r.stderr)
            self.assertEqual((self.state / "remus").read_text().strip(), "nemesis")
        finally:
            holder.kill()

    def test_stale_lock_is_taken_over(self):
        lock = self.state / "lock.d"
        lock.mkdir()
        (lock / "pid").write_text("999999")
        r = self.run_mm("remus", "pollux")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual((self.state / "remus").read_text().strip(), "pollux")
        self.assertFalse(lock.exists(), "lock released on exit")


if __name__ == "__main__":
    unittest.main()
