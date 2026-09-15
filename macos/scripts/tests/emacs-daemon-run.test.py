"""Disposable tests for run launch and diagnostic collection; no live sockets."""
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import time
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "emacs-daemon-run.py"


class DiagnosticsTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="daemon-run-test-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        spec = importlib.util.spec_from_file_location("daemon_run", SCRIPT)
        self.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.module)

    def test_rotation_bounds_utf8_and_labels_discarded_history(self):
        writer = self.module.RotatingLog(self.root, limit=128)
        for _ in range(40):
            writer.write("界" * 19 + "\n")
        writer.write("final-fixture\n")
        for name in ("daemon-stderr.log", "daemon-stderr.log.1"):
            data = (self.root / name).read_bytes()
            self.assertLessEqual(len(data), 128)
            data.decode("utf-8", errors="strict")
            self.assertEqual((self.root / name).stat().st_mode & 0o777, 0o600)
        self.assertIn("final-fixture", (self.root / "daemon-stderr.log").read_text())
        self.assertIn("truncated", (self.root / "daemon-stderr.log.1").read_text())

    def test_writer_failure_drains_entire_input_and_marks_missing(self):
        source = io.BytesIO(b"fixture\n" * 100000)
        class FailedWriter:
            def write(self, text):
                raise OSError("fixture disk failure")
        result = self.module.collect(source, FailedWriter())
        self.assertEqual(source.tell(), len(source.getvalue()))
        self.assertFalse(result["complete"])

    def test_log_open_failure_is_missing_even_when_daemon_is_silent(self):
        run = self.module.create_run(self.root, "fixture", self.root)
        (run / "daemon-stderr.log").unlink()
        (run / "daemon-stderr.log").mkdir()
        emacs = self.fixture_program("emacs-fixture", "pass\n")
        (run / "launch.json").write_text(json.dumps({"emacs": str(emacs),
                                                    "server": "fixture", "init_directory": str(self.root)}))
        fd = os.open(str(self.root / "lock"), os.O_CREAT | os.O_RDWR, 0o600)
        self.module.supervise(run, fd)
        status = json.loads((run / "stderr-status.json").read_text())
        self.assertFalse(status["complete"])
        self.assertIsNotNone(status["writer_error"])
        self.assertEqual(status["exit_code"], 0)

    def test_stalled_writer_cannot_block_reader(self):
        release = threading.Event()
        class StalledWriter:
            def write(self, text):
                release.wait(10)
        source = io.BytesIO(b"x" * (4 * 1024 * 1024))
        start = time.monotonic()
        try:
            result = self.module.collect(source, StalledWriter(), finish_timeout=0.05)
            self.assertLess(time.monotonic() - start, 2)
            self.assertEqual(source.tell(), 4 * 1024 * 1024)
            self.assertFalse(result["complete"])
        finally:
            release.set()

    def test_stalled_writer_initialization_cannot_block_reader(self):
        release = threading.Event()
        def factory():
            release.wait(10)
            return type("Writer", (), {"write": lambda self, text: None})()
        source = io.BytesIO(b"startup-fixture\n")
        try:
            result = self.module.collect(source, factory, finish_timeout=0.05)
            self.assertEqual(source.tell(), len(source.getvalue()))
            self.assertFalse(result["complete"])
            # An initialization stall must be unfinished, not misreported as
            # a failed call to write() on the factory itself.
            self.assertIsNone(result["writer_error"])
        finally:
            release.set()

    def test_split_utf8_sequence_survives_input_chunks(self):
        class ByteReader(io.BytesIO):
            def read(self, size=-1):
                return super().read(1)
        result = self.module.collect(ByteReader("before界after\n".encode()),
                                     self.module.RotatingLog(self.root))
        self.assertTrue(result["complete"])
        self.assertEqual((self.root / "daemon-stderr.log").read_text(), "before界after\n")

    def test_sustained_small_pipe_writes_survive_default_queue(self):
        # A daemon writes stderr unbuffered, so the collector sees thousands
        # of tiny pipe reads.  The writer must keep up with the default queue
        # or a burst loses most of its evidence before rotation ever happens.
        lines = "".join("%05d %s\n" % (i, "s" * 1017) for i in range(3072))
        payload = (lines + "END-FIXTURE\n").encode()
        read_fd, write_fd = os.pipe()

        def produce():
            for offset in range(0, len(payload), 64):
                os.write(write_fd, payload[offset:offset + 64])
            os.close(write_fd)

        producer = threading.Thread(target=produce)
        producer.start()
        with os.fdopen(read_fd, "rb", buffering=0) as source:
            result = self.module.collect(source, lambda: self.module.RotatingLog(self.root))
        producer.join()
        self.assertTrue(result["complete"], result)
        current = (self.root / "daemon-stderr.log").read_bytes()
        previous = (self.root / "daemon-stderr.log.1").read_bytes()
        self.assertLessEqual(len(current), 2 * 1024 * 1024)
        self.assertLessEqual(len(previous), 2 * 1024 * 1024)
        self.assertTrue(current.endswith(b"END-FIXTURE\n"))
        self.assertTrue(previous.startswith(b"[older stderr truncated]\n"))
        for line in current.decode("utf-8").splitlines():
            self.assertTrue(len(line) == 1023 or line == "END-FIXTURE", line[:24])
        self.assertEqual(len(current), 1024 * 1024 + len(b"END-FIXTURE\n"))

    def test_symlink_log_never_touches_target(self):
        outside = self.root / "outside"
        outside.write_text("untouched")
        (self.root / "daemon-stderr.log").symlink_to(outside)
        with self.assertRaises(ValueError):
            self.module.RotatingLog(self.root)
        self.assertEqual(outside.read_text(), "untouched")

    def test_metadata_roundtrips_through_real_emacs_reader(self):
        init = self.root / 'init "界\n'
        init.mkdir()
        run = self.module.create_run(self.root, "fixture", init)
        emacs = "/opt/homebrew/opt/emacs-plus@30/bin/emacs"
        library = SCRIPT.parents[1] / "emacs/.emacs.d/lisp"
        env = dict(os.environ, FIXTURE_RUN=str(run), FIXTURE_INIT=str(init))
        result = subprocess.run([emacs, "--batch", "-Q", "-L", str(library),
                                 "-l", "mr-x-crash-diagnostics", "--eval",
                                 '(let ((data (mr-x/crash-run-metadata (getenv "FIXTURE_RUN")))) (princ (if (and (not (plist-get data :pid)) (equal (plist-get data :init-directory) (file-truename (concat (getenv "FIXTURE_INIT") "/")))) "early" "wrong")))'],
                                env=env, capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "early")

    def fixture_program(self, name, source):
        path = self.root / name
        path.write_text("#!" + sys.executable + "\n" + source)
        path.chmod(0o700)
        return path

    def launch(self, emacs, client, timeout="0.5"):
        environment_tmp = tempfile.mkdtemp(dir=str(self.root))
        return subprocess.run(["bash", str(SCRIPT.with_suffix(".sh")),
                               "--server", "fixture", "--init-directory", str(self.root),
                               "--emacs", str(emacs), "--emacsclient", str(client),
                               "--runtime-directory", str(self.root / "runtime"),
                               "--timeout", timeout],
                              env=dict(os.environ, TMPDIR=environment_tmp),
                              capture_output=True, text=True, timeout=8)

    def test_existing_socket_refuses_launch_without_creating_run(self):
        emacs = self.fixture_program("emacs-fixture", "raise RuntimeError('must not launch')\n")
        client = self.fixture_program("client-fixture", "print('t')\n")
        result = self.launch(emacs, client)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("already responds", result.stderr)
        self.assertFalse((self.root / "var").exists())

    def test_timeout_preserves_child_and_lock_across_temp_environments(self):
        emacs = self.fixture_program("emacs-fixture", "import time,sys\ntime.sleep(1)\nsys.stderr.write('survived-timeout\\n')\n")
        client = self.fixture_program("client-fixture", "import sys\nsys.exit(1)\n")
        first = self.launch(emacs, client, "0.1")
        self.assertNotEqual(first.returncode, 0)
        second = self.launch(emacs, client, "0.1")
        self.assertNotEqual(second.returncode, 0)
        runs = list((self.root / "var/crash-recovery/runs").glob("run-*"))
        self.assertEqual(len(runs), 1)
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            status = json.loads((runs[0] / "stderr-status.json").read_text())
            if status["state"] == "finished":
                break
            time.sleep(0.02)
        self.assertEqual(status["exit_code"], 0)
        self.assertIn("survived-timeout", (runs[0] / "daemon-stderr.log").read_text())

    def test_inherited_stderr_cannot_hold_lock_after_daemon_exits(self):
        emacs = self.fixture_program("emacs-fixture", '''import subprocess,sys
subprocess.Popen([sys.executable,"-c","import time;time.sleep(3)"],stdout=subprocess.DEVNULL)
sys.stderr.write("daemon-exit-fixture\\n")
''')
        client = self.fixture_program("client-fixture", "import sys\nsys.exit(1)\n")
        result = self.launch(emacs, client, "0.7")
        run = Path(json.loads(result.stdout)["run_directory"])
        status = json.loads((run / "stderr-status.json").read_text())
        self.assertEqual(status["state"], "finished")
        self.assertFalse(status["complete"])
        self.assertEqual(status["exit_code"], 0)

    def readiness_fixture(self, stale=False, uninitialized=False):
        emacs = self.fixture_program("emacs-fixture", '''import os,json,time,sys
from pathlib import Path
init=Path(sys.argv[3])
(init/"ready.json").write_text(json.dumps({"run":os.environ["MR_X_EMACS_RUN_DIRECTORY"]}))
time.sleep(1)
''')
        client = self.fixture_program("client-fixture", '''import os,json,subprocess,sys
from pathlib import Path
if sys.argv[-1] == "t": sys.exit(1)
init=Path(__file__).parent
if not (init/"ready.json").exists(): sys.exit(1)
run=Path(json.loads((init/"ready.json").read_text())["run"])
env=dict(os.environ, MR_X_EMACS_RUN_ID=run.name, MR_X_EMACS_RUN_DIRECTORY=str(run))
''' + ('env["MR_X_EMACS_RUN_ID"]="stale-run"\n' if stale else '') + '''
setup='(setq server-name "fixture" user-emacs-directory '+json.dumps(str(init)+"/")+')'
''' + ('' if uninitialized else '''setup+='(setq mr-x/crash-runtime--identity (list :run-id (getenv "MR_X_EMACS_RUN_ID") :pid (emacs-pid)))'
''') + '''
r=subprocess.run(["/opt/homebrew/opt/emacs-plus@30/bin/emacs","--batch","-Q","--eval","(progn "+setup+")","--eval","(prin1 "+sys.argv[-1]+")"],env=env)
sys.exit(r.returncode)
''')
        result = self.launch(emacs, client, "0.6")
        run = Path(json.loads(result.stdout)["run_directory"])
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            if json.loads((run / "stderr-status.json").read_text())["state"] == "finished":
                break
            time.sleep(0.02)
        return result

    def test_readiness_accepts_exact_run_using_real_elisp_expression(self):
        result = self.readiness_fixture()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["status"], "ready")

    def test_readiness_rejects_stale_run_on_same_named_socket(self):
        result = self.readiness_fixture(stale=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(json.loads(result.stdout)["status"], "not-ready")

    def test_readiness_waits_for_runtime_hook_installation(self):
        result = self.readiness_fixture(uninitialized=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(json.loads(result.stdout)["status"], "not-ready")

    def test_failed_initialization_retains_early_stderr_and_identity(self):
        emacs = self.fixture_program("emacs-fixture", '''import os,sys
from pathlib import Path
run=Path(os.environ["MR_X_EMACS_RUN_DIRECTORY"])
assert run.name == os.environ["MR_X_EMACS_RUN_ID"]
assert (run/"metadata.el").exists()
assert (run/"daemon-stderr.log").exists()
assert sys.argv[1] == "--fg-daemon=fixture"
assert sys.argv[2] == "--init-directory"
assert "mr-x-crash-runtime" in sys.argv
assert "mr-x/crash-runtime-arm" in sys.argv
assert Path(sys.argv[sys.argv.index("--directory")+1]) == Path(sys.argv[3])/"lisp"
sys.stderr.write("early-start-fixture\\n")
sys.exit(23)
''')
        client = self.fixture_program("client-fixture", "import sys\nsys.exit(1)\n")
        result = subprocess.run(["bash", str(SCRIPT.with_suffix(".sh")),
                                 "--server", "fixture", "--init-directory", str(self.root),
                                 "--emacs", str(emacs), "--emacsclient", str(client),
                                 "--runtime-directory", str(self.root / "runtime"),
                                 "--timeout", "2"],
                                env=dict(os.environ, TMPDIR=str(self.root)),
                                capture_output=True, text=True, timeout=8)
        self.assertNotEqual(result.returncode, 0)
        runs = list((self.root / "var/crash-recovery/runs").glob("run-*"))
        self.assertEqual(len(runs), 1)
        status_path = runs[0] / "stderr-status.json"
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            status = json.loads(status_path.read_text())
            if status["state"] == "finished":
                break
            time.sleep(0.02)
        self.assertEqual(status["exit_code"], 23)
        self.assertTrue(status["complete"])
        self.assertIn("early-start-fixture", (runs[0]/"daemon-stderr.log").read_text())


if __name__ == "__main__":
    unittest.main()
