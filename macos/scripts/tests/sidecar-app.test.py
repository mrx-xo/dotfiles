"""Exercise the launcher against a fake device API, never a real iPad."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import subprocess
import sys
import os
import signal

SPEC = importlib.util.spec_from_file_location("sidecar_app", Path(__file__).parents[1] / "sidecar-app.py")
app = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(app)


class Device:
    def __init__(self, locks):
        self.locks = iter(locks)
        self.launches = []

    def __call__(self, args, timeout):
        if "lockState" in args:
            Path(args[args.index("--json-output") + 1]).write_text(json.dumps({"result": {"passcodeRequired": next(self.locks)}}))
        elif "launch" in args:
            self.launches.append(args)
        else:
            raise AssertionError(args)


class LaunchTest(unittest.TestCase):
    def test_locked_device_waits_then_launches_native_bundle_without_url(self):
        device = Device([True, False, False])
        waits = []
        app.open_app("Test iPad", "io.marx.aidos", run=device, sleep=waits.append)
        self.assertEqual(waits, [2])
        self.assertEqual(len(device.launches), 1)
        self.assertEqual(device.launches[0][-1], "io.marx.aidos")
        self.assertNotIn("--payload-url", device.launches[0])

    def test_missing_lock_information_never_launches(self):
        def malformed(args, timeout):
            self.assertIn("lockState", args)
            Path(args[args.index("--json-output") + 1]).write_text('{"result": {}}')
        with self.assertRaises(RuntimeError):
            app.open_app("Test iPad", "io.marx.aidos", run=malformed)

    def test_failure_is_not_retried_as_success(self):
        def failed(args, timeout):
            raise RuntimeError("device unavailable")
        with self.assertRaisesRegex(RuntimeError, "device unavailable"):
            app.open_app("Test iPad", "io.marx.aidos", run=failed)

    def test_locked_timeout_does_not_launch(self):
        device = Device([True])
        times = iter([0, 0, 0, 3])
        with self.assertRaisesRegex(RuntimeError, "unlock"):
            app.open_app("Test iPad", "io.marx.aidos", run=device, sleep=lambda _: None,
                         clock=lambda: next(times), wait=2)
        self.assertEqual(device.launches, [])

    def test_relock_during_launch_waits_for_authentication_again(self):
        device = Device([False, True, False, False])
        waits = []
        app.open_app("Test iPad", "io.marx.aidos", run=device, sleep=waits.append)
        self.assertEqual(len(device.launches), 2)
        self.assertEqual(waits, [2])

    def test_device_timeout_never_drops_below_five_seconds(self):
        device = Device([True, True])
        now = [0]
        def run(args, timeout):
            self.assertGreaterEqual(int(args[args.index("--timeout") + 1]), 5)
            device(args, timeout)
        with self.assertRaisesRegex(RuntimeError, "unlock"):
            app.open_app("Test iPad", "io.marx.aidos", run=run,
                         sleep=lambda seconds: now.__setitem__(0, now[0] + seconds),
                         clock=lambda: now[0], wait=7)

    def test_launch_error_after_relock_waits_and_retries(self):
        device = Device([False, True, False, False])
        def run(args, timeout):
            device(args, timeout)
            if "launch" in args and len(device.launches) == 1:
                raise RuntimeError("device locked")
        app.open_app("Test iPad", "io.marx.aidos", run=run, sleep=lambda _: None)
        self.assertEqual(len(device.launches), 2)

    def test_launch_error_while_unlocked_propagates(self):
        device = Device([False, False])
        def run(args, timeout):
            device(args, timeout)
            if "launch" in args:
                raise RuntimeError("app not installed")
        with self.assertRaisesRegex(RuntimeError, "app not installed"):
            app.open_app("Test iPad", "io.marx.aidos", run=run)
        self.assertEqual(len(device.launches), 1)

    def test_command_timeout_terminates_its_child(self):
        process = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)"],
                                   stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        with patch.object(app.subprocess, "Popen", return_value=process):
            with self.assertRaises(subprocess.TimeoutExpired):
                app.run_command(["unused"], 0.05)
        self.assertIsNotNone(process.poll())

    def test_cancellation_during_child_creation_terminates_child(self):
        process = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)"],
                                   stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        old = signal.getsignal(signal.SIGTERM)
        def cancel(_signum, _frame):
            raise SystemExit(130)
        def spawn(*_args, **_kwargs):
            os.kill(os.getpid(), signal.SIGTERM)
            return process
        signal.signal(signal.SIGTERM, cancel)
        try:
            with patch.object(app.subprocess, "Popen", side_effect=spawn):
                with self.assertRaises(SystemExit):
                    app.run_command(["unused"], 1)
            self.assertIsNotNone(process.poll())
        finally:
            signal.signal(signal.SIGTERM, old)
            if process.poll() is None:
                process.terminate()
                process.wait()
            if not process.stdout.closed:
                process.stdout.close()


if __name__ == "__main__":
    unittest.main()
