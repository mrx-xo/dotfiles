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


ROMULUS = "8C207E30-FF6D-4624-A998-F6D7962597F6"
REMUS = "0CDDE5CC-F566-4B56-85FD-48B8EA229946"
LUPA = "56FEF42D-88B7-46E3-9C9B-7746A0929EB7"

# A display dropped with --connected=off stops enumerating and its DDC reads
# fail, like the real BetterDisplay; $HOME/visible is the enumerated set.
FAKE_BETTERDISPLAY = r'''
echo "$*" >> "$HOME/bd.log"
uuid=$(printf '%s\n' "$@" | sed -n 's/^--uuid=//p')
case "$*" in
  *--connected=off*) grep -v "$uuid" "$HOME/visible" > "$HOME/visible.new"
                     mv "$HOME/visible.new" "$HOME/visible" ;;
  *--connected=on*)  echo "$uuid" >> "$HOME/visible" ;;
  get*) grep -q "$uuid" "$HOME/visible" || exit 1
        echo 4370 ;;
esac
exit 0
'''


class FakeDesk(unittest.TestCase):
    """ROMULUS, REMUS and LUPA all on POLLUX, behind the fake BetterDisplay."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.home = Path(self.tmp.name)
        self.state = self.home / ".local/state/monitor-mode"
        self.state.mkdir(parents=True)
        (self.state / "romulus").write_text("pollux\n")
        (self.state / "remus").write_text("pollux\n")
        self.show(ROMULUS, REMUS, LUPA)
        bindir = self.home / "bin"
        bindir.mkdir()
        for name, body in {
            "betterdisplaycli": FAKE_BETTERDISPLAY,
            "displayplacer": 'sed "s/^/Persistent screen id: /" "$HOME/visible"',
            "osascript": "exit 0",
            "ssh": "exit 0",
            # enumerated displays, so the restore wait sees a reconnect at once
            "yabai": 'cat "$HOME/visible"',
        }.items():
            exe = bindir / name
            exe.write_text("#!/bin/bash\n" + body + "\n")
            exe.chmod(0o755)
        self.env = dict(os.environ, HOME=self.tmp.name, MONITOR_MODE_LOCK_TRIES="2",
                        PATH=str(bindir) + ":/usr/bin:/bin")

    def tearDown(self):
        self.tmp.cleanup()

    def show(self, *uuids):
        (self.home / "visible").write_text("".join(u + "\n" for u in uuids))

    def visible(self):
        return set((self.home / "visible").read_text().split())

    def machine(self, display):
        return (self.state / display).read_text().strip()

    def run_mm(self, *args):
        return subprocess.run(["/bin/bash", str(SCRIPT), *args], env=self.env,
                              capture_output=True, text=True, timeout=20)


class SoloTest(FakeDesk):
    def test_solo_leaves_only_the_named_dell_on_pollux(self):
        r = self.run_mm("solo", "remus")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.visible(), {REMUS})
        self.assertEqual(self.machine("remus"), "pollux")
        self.assertEqual(self.machine("romulus"), "off")
        self.assertEqual(self.machine("lupa"), "off")

    def test_solo_pulls_the_named_dell_back_from_another_machine(self):
        (self.state / "remus").write_text("nemesis\n")
        self.show(ROMULUS, LUPA)
        r = self.run_mm("solo", "remus")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.visible(), {REMUS})
        self.assertEqual(self.machine("remus"), "pollux")

    def test_solo_leaves_a_dell_showing_another_machine_alone(self):
        (self.state / "romulus").write_text("nemesis\n")
        self.show(REMUS, LUPA)
        r = self.run_mm("solo", "remus")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.machine("romulus"), "nemesis")
        self.assertEqual(self.visible(), {REMUS})

    def test_solo_off_brings_back_what_solo_dropped(self):
        self.run_mm("solo", "remus")
        r = self.run_mm("solo", "off")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.visible(), {ROMULUS, REMUS, LUPA})
        self.assertEqual(self.machine("romulus"), "pollux")
        self.assertEqual(self.machine("lupa"), "pollux")

    def test_solo_off_leaves_a_dell_showing_another_machine_alone(self):
        (self.state / "romulus").write_text("nemesis\n")
        self.show(REMUS, LUPA)
        self.run_mm("solo", "remus")
        self.run_mm("solo", "off")
        self.assertEqual(self.machine("romulus"), "nemesis")
        self.assertEqual(self.visible(), {REMUS, LUPA})

    def test_a_preset_brings_a_dropped_dell_back(self):
        self.run_mm("solo", "remus")
        r = self.run_mm("romulus", "pollux")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn(ROMULUS, self.visible())
        self.assertEqual(self.machine("romulus"), "pollux")

    def test_reset_brings_lupa_back(self):
        self.run_mm("solo", "remus")
        r = self.run_mm("reset")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.visible(), {ROMULUS, REMUS, LUPA})
        self.assertEqual(self.machine("lupa"), "pollux")

    def test_solo_without_a_display_is_refused(self):
        r = self.run_mm("solo")
        self.assertEqual(r.returncode, 1)
        self.assertIn("usage", r.stderr)
        self.assertEqual(self.visible(), {ROMULUS, REMUS, LUPA})

    def test_json_reports_a_dropped_dell_as_off(self):
        self.run_mm("solo", "remus")
        import json
        data = json.loads(self.run_mm("json").stdout)
        self.assertEqual(data["romulus"]["machine"], "off")
        self.assertEqual(data["remus"]["machine"], "pollux")


class KillTest(FakeDesk):
    def test_kill_drops_just_that_display(self):
        r = self.run_mm("kill", "lupa")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.visible(), {ROMULUS, REMUS})
        self.assertEqual(self.machine("lupa"), "off")
        self.assertEqual(self.machine("romulus"), "pollux")

    def test_kill_again_brings_lupa_back(self):
        self.run_mm("kill", "lupa")
        r = self.run_mm("kill", "lupa")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.visible(), {ROMULUS, REMUS, LUPA})
        self.assertEqual(self.machine("lupa"), "pollux")

    def test_kill_again_brings_a_dell_back(self):
        self.run_mm("kill", "romulus")
        self.assertEqual(self.visible(), {REMUS, LUPA})
        self.assertEqual(self.machine("romulus"), "off")
        r = self.run_mm("kill", "romulus")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.visible(), {ROMULUS, REMUS, LUPA})
        self.assertEqual(self.machine("romulus"), "pollux")

    def test_kill_refuses_a_dell_showing_another_machine(self):
        (self.state / "remus").write_text("nemesis\n")
        self.show(ROMULUS, LUPA)
        r = self.run_mm("kill", "remus")
        self.assertEqual(r.returncode, 1)
        self.assertEqual(self.machine("remus"), "nemesis")
        self.assertEqual(self.visible(), {ROMULUS, LUPA})

    def test_kill_refuses_the_last_display(self):
        self.show(REMUS)
        r = self.run_mm("kill", "remus")
        self.assertEqual(r.returncode, 1)
        self.assertIn("last display", r.stderr)
        self.assertEqual(self.visible(), {REMUS})
        self.assertEqual(self.machine("remus"), "pollux")

    def test_kill_without_a_display_is_refused(self):
        r = self.run_mm("kill")
        self.assertEqual(r.returncode, 1)
        self.assertIn("usage", r.stderr)
        self.assertEqual(self.visible(), {ROMULUS, REMUS, LUPA})


if __name__ == "__main__":
    unittest.main()
