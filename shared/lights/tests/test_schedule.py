"""Local-clock schedule regression tests; no device access."""
import datetime
import os
import contextlib
import io
import json
import runpy
from pathlib import Path
import sys
import time
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import schedule


@unittest.skipUnless(hasattr(time, 'tzset'), 'requires local timezone switching')
class ScheduleTests(unittest.TestCase):
    def setUp(self):
        self.previous = os.environ.get('TZ')
        os.environ['TZ'] = 'America/Chicago'
        time.tzset()

    def tearDown(self):
        if self.previous is None:
            os.environ.pop('TZ', None)
        else:
            os.environ['TZ'] = self.previous
        time.tzset()

    def check_boundary(self, before, after, hours=None):
        now = datetime.datetime.fromisoformat(before).timestamp()
        expected = datetime.datetime.fromisoformat(after).timestamp()
        self.assertEqual(schedule.next_boundary(now), expected)
        with patch.object(schedule.time, 'time', return_value=now):
            self.assertEqual(schedule.next_boundary(), expected)
        if hours is not None:
            self.assertEqual((expected - now) / 3600, hours)

    def test_day_boundaries(self):
        for before, after in [
            ('2026-09-12T07:59:59', '2026-09-12T08:00:00'),
            ('2026-09-12T08:00:00', '2026-09-12T23:00:00'),
            ('2026-09-12T22:59:59', '2026-09-12T23:00:00'),
            ('2026-09-12T23:00:00', '2026-09-13T08:00:00'),
            ('2026-12-31T23:59:59', '2027-01-01T08:00:00'),
        ]:
            with self.subTest(before=before):
                self.check_boundary(before, after)
        self.assertEqual((schedule.DAY_START_HOUR, schedule.DAY_END_HOUR), (8, 23))

    def test_spring_dst_uses_local_clock(self):
        self.check_boundary('2026-03-07T23:00:00', '2026-03-08T08:00:00', 8)

    def test_fall_dst_uses_local_clock(self):
        self.check_boundary('2026-10-31T23:00:00', '2026-11-01T08:00:00', 10)


class CliRegressionTests(unittest.TestCase):
    def test_cli_uses_shared_boundary_and_preserves_status_json(self):
        cli_path = Path(__file__).resolve().parents[3] / 'macos/scripts/lights/lightsctl'
        with patch('subprocess.run', side_effect=AssertionError('no process access')):
            cli = runpy.run_path(str(cli_path))
            self.assertIs(cli['next_boundary'], schedule.next_boundary)
            command = cli['cmd_status']
            observed = {'on': False, 'effect': 'black'}
            with patch.dict(command.__globals__, {'read_status': lambda: (observed, 2)}):
                output = io.StringIO()
                with contextlib.redirect_stdout(output):
                    command(type('Args', (), {'json': True})())
            self.assertEqual(json.loads(output.getvalue()),
                             dict(observed, engine_age=2, wedged=False))
