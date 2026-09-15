"""Configuration-only copy tests with synthetic runtime and IPC fixtures."""
import importlib.util
import fcntl
import hashlib
from pathlib import Path
import os
import socket
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "emacs-sandbox-copy.py"


class SandboxCopyTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="sandbox-copy-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.source = self.root / "source"
        self.source.mkdir()
        (self.source / "init.el").write_text("; fixture config\n")
        self.dest = self.root / "sandbox"
        spec = importlib.util.spec_from_file_location("sandbox_copy", SCRIPT)
        self.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.module)

    def test_runtime_and_live_ipc_never_enter_copy(self):
        for name in ("session-state.el", "yabai-state.json", "clean-exit", "SingletonCookie"):
            (self.source / name).write_text("private runtime fixture")
        for name in ("var/crash-recovery/runs/old", "crash-state", "server", "tmp", "search-output"):
            directory = self.source / name
            directory.mkdir(parents=True, exist_ok=True)
            (directory / "evidence").write_text("runtime")
        sock = socket.socket(socket.AF_UNIX)
        self.addCleanup(sock.close)
        sock.bind(str(self.source / "live.socket"))
        os.mkfifo(str(self.source / "live.fifo"))
        result = self.module.provision(self.source, self.dest)
        self.assertEqual(sorted(p.name for p in self.dest.iterdir()), ["init.el"])
        self.assertGreater(len(result["skipped"]), 5)
        self.assertEqual(self.dest.stat().st_mode & 0o777, 0o700)

    def test_internal_package_links_rebased_external_and_runtime_links_excluded(self):
        package = self.source / "elpaca/sources/fixture"
        package.mkdir(parents=True)
        (package / "package.el").write_text("; fixture package")
        (self.source / "elpaca/repos").symlink_to(self.source / "elpaca/sources")
        (self.source / "var").mkdir()
        (self.source / "var/state").write_text("runtime")
        (self.source / "indirect-state").symlink_to(self.source / "var/state")
        outside = self.root / "outside.el"
        outside.write_text("external fixture")
        (self.source / "outside-link.el").symlink_to(outside)
        self.module.provision(self.source, self.dest)
        self.assertEqual((self.dest / "elpaca/repos/fixture/package.el").read_text(), "; fixture package")
        self.assertTrue(str((self.dest / "elpaca/repos").resolve()).startswith(str(self.dest)))
        self.assertFalse((self.dest / "indirect-state").exists())
        self.assertFalse((self.dest / "outside-link.el").exists())

    def test_replace_preserves_previous_sandbox_and_fails_closed_on_bad_source(self):
        self.dest.mkdir()
        (self.dest / "old-evidence").write_text("preserved")
        result = self.module.provision(self.source, self.dest, replace=True)
        self.assertEqual((Path(result["backup"]) / "old-evidence").read_text(), "preserved")
        self.assertFalse((self.dest / "old-evidence").exists())
        (self.source / "init.el").unlink()
        with self.assertRaises(ValueError):
            self.module.provision(self.source, self.dest, replace=True)
        self.assertTrue((self.dest / "init.el").exists())

    def test_overlapping_source_destination_is_rejected(self):
        for destination in (self.source, self.source / "nested", self.root):
            with self.assertRaises(ValueError):
                self.module.provision(self.source, destination, replace=True)
        self.assertTrue((self.source / "init.el").exists())

    def test_active_run_lock_prevents_fresh_copy(self):
        runtime = self.root / "runtime"
        runtime.mkdir()
        self.dest.mkdir()
        (self.dest / "evidence").write_text("preserved")
        with (runtime / (hashlib.sha256(b"sandbox").hexdigest()+".lock")).open("w") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            result = subprocess.run([sys.executable, str(SCRIPT), str(self.source), str(self.dest),
                                     "--replace", "--runtime-directory", str(runtime)],
                                    capture_output=True, text=True, timeout=8)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.dest / "evidence").read_text(), "preserved")
        self.assertFalse(list(self.root.glob("sandbox.previous-*")))


if __name__ == "__main__":
    unittest.main()
