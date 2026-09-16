"""Decision and recovery tests for the lights engine watchdog, on temp state only."""
import os
from pathlib import Path
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'windows' / 'scripts'))
import icue_watchdog  # noqa: E402


class DecideTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.state = Path(self.temp.name)
        self.now = 1_800_000_000.0

    def write_status(self, age):
        status = self.state / 'status.json'
        status.write_text('{"on": true}')
        os.utime(status, (self.now - age, self.now - age))

    def test_fresh_status_with_engine_is_ok(self):
        self.write_status(age=1)
        self.assertEqual(icue_watchdog.decide(self.state, [2372], self.now), 'ok')

    def test_stale_status_with_engine_restarts(self):
        self.write_status(age=61)
        self.assertEqual(icue_watchdog.decide(self.state, [2372], self.now), 'restart:stale')

    def test_missing_engine_restarts(self):
        self.write_status(age=1)
        self.assertEqual(icue_watchdog.decide(self.state, [], self.now), 'restart:missing')

    def test_missing_status_with_engine_counts_as_stale(self):
        self.assertEqual(icue_watchdog.decide(self.state, [2372], self.now), 'restart:stale')

    def test_stop_flag_means_deliberate_handback(self):
        self.write_status(age=9999)
        (self.state / 'stop.flag').touch()
        self.assertEqual(icue_watchdog.decide(self.state, [], self.now), 'skip:stop-flag')

    def test_recent_restart_holds_off(self):
        self.write_status(age=61)
        sentinel = self.state / icue_watchdog.SENTINEL_NAME
        sentinel.touch()
        os.utime(sentinel, (self.now - 120, self.now - 120))
        self.assertEqual(icue_watchdog.decide(self.state, [2372], self.now), 'skip:cooldown')

    def test_old_restart_does_not_hold_off(self):
        self.write_status(age=61)
        sentinel = self.state / icue_watchdog.SENTINEL_NAME
        sentinel.touch()
        os.utime(sentinel, (self.now - 601, self.now - 601))
        self.assertEqual(icue_watchdog.decide(self.state, [2372], self.now), 'restart:stale')


class RestartTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.state = Path(self.temp.name)
        self.commands = []

    def run_command(self, argv):
        self.commands.append(argv)
        return 0

    def test_restart_kills_engine_then_relaunches_task_and_records(self):
        icue_watchdog.restart(self.state, [35452, 2372], 'restart:stale', 'age=45987s',
                              run=self.run_command, now=1_800_000_000.0)
        self.assertEqual(self.commands, [
            ['taskkill', '/F', '/T', '/PID', '35452'],
            ['taskkill', '/F', '/T', '/PID', '2372'],
            ['schtasks', '/run', '/tn', icue_watchdog.TASK_NAME],
        ])
        self.assertTrue((self.state / icue_watchdog.SENTINEL_NAME).exists())
        log = (self.state / 'watchdog.log').read_text()
        self.assertIn('restart:stale', log)
        self.assertIn('age=45987s', log)
        self.assertIn('35452', log)

    def test_restart_with_no_engine_only_relaunches(self):
        icue_watchdog.restart(self.state, [], 'restart:missing', 'no engine process',
                              run=self.run_command, now=1_800_000_000.0)
        self.assertEqual(self.commands, [['schtasks', '/run', '/tn', icue_watchdog.TASK_NAME]])

    def test_failed_relaunch_is_logged_not_raised(self):
        icue_watchdog.restart(self.state, [], 'restart:missing', 'no engine process',
                              run=lambda argv: 1, now=1_800_000_000.0)
        self.assertIn('schtasks exit 1', (self.state / 'watchdog.log').read_text())


class ParsePidsTests(unittest.TestCase):
    def test_parses_powershell_pid_lines(self):
        self.assertEqual(icue_watchdog.parse_pids('35452\r\n2372\r\n'), [35452, 2372])

    def test_empty_output_means_no_engine(self):
        self.assertEqual(icue_watchdog.parse_pids('\r\n'), [])


if __name__ == '__main__':
    unittest.main()
