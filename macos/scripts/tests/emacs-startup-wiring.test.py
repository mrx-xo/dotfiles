"""Wrapper behavior using copied scripts and disposable executable fixtures.

Only baseline machine-path literals are substituted, so even the old wrappers
cannot execute real Emacs or operate on the user's sandbox.  Command behavior
and branching come from the real wrapper scripts.
"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

SCRIPTS = Path(__file__).resolve().parents[1]


class WiringTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="wiring-test-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.sandbox = self.root / "sandbox"
        self.sandbox.mkdir()
        self.source = self.root / "source"
        self.source.mkdir()
        for folder in (self.source, self.sandbox):
            (folder / "init.el").write_text("; fixture init\n")
            (folder / "early-init.el").write_text("; fixture early init\n")
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.program("emacs", "import sys\nsys.exit(0)\n")
        self.program("pkill", "from pathlib import Path\nPath(__file__).with_name('forbidden-kill').touch()\n")
        self.program("emacsclient", '''import os,sys
from pathlib import Path
root=Path(__file__).parent.parent
if os.environ.get("FIXTURE_MODE")=="hang":
 import time;time.sleep(30)
if "(kill-emacs)" in sys.argv[-1]:
 (root/"kill-called").touch();sys.exit(0)
if os.environ.get("FIXTURE_MODE")=="wrong": print("nil");sys.exit(0)
if "-c" in sys.argv: (root/"frame-called").touch();sys.exit(0)
sys.exit(1)
''')
        helper = self.root / "emacs-daemon-run.sh"
        helper.write_text('#!/bin/bash\nprintf "%s\\n" "$@" > "$(dirname "$0")/helper-args"\n')
        helper.chmod(0o700)
        shutil.copyfile(SCRIPTS / "emacs-sandbox-copy.py", self.root / "emacs-sandbox-copy.py")
        self.env = dict(os.environ, PATH=str(self.bin)+os.pathsep+os.environ["PATH"],
                        EMACS=str(self.bin / "emacs"), EMACSCLIENT=str(self.bin / "emacsclient"),
                        EMACS_RUNTIME_DIRECTORY=str(self.root / "runtime"),
                        SANDBOX_DIR=str(self.sandbox), EMACS_CONFIG_SOURCE=str(self.source))

    def program(self, name, source):
        path = self.bin / name
        path.write_text("#!"+sys.executable+"\n"+source)
        path.chmod(0o700)

    def run_wrapper(self, name, *args):
        text = (SCRIPTS / name).read_text()
        text = text.replace('/opt/homebrew/opt/emacs-plus@30/bin/emacsclient',str(self.bin / "emacsclient"))
        text = text.replace('/opt/homebrew/opt/emacs-plus@30/bin/emacs',str(self.bin / "emacs"))
        text = text.replace('SANDBOX_DIR="$HOME/.emacs-sandbox"', 'SANDBOX_DIR="'+str(self.sandbox)+'"')
        script = self.root / name
        script.write_text(text)
        return subprocess.run(["bash",str(script),*args],env=self.env,capture_output=True,text=True,timeout=8)

    def test_production_start_uses_shared_helper_without_broad_kills(self):
        result = self.run_wrapper("emacs-daemon-start.sh")
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertFalse((self.bin / "forbidden-kill").exists())
        self.assertIn("server",(self.root / "helper-args").read_text())

    def test_sandbox_cold_start_uses_shared_helper(self):
        result = self.run_wrapper("emacs-sandbox.sh")
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertIn("sandbox",(self.root / "helper-args").read_text())
        self.assertTrue((self.root / "frame-called").exists())

    def test_wrong_identity_refuses_sandbox_shutdown(self):
        self.env["FIXTURE_MODE"]="wrong"
        result = self.run_wrapper("emacs-sandbox.sh","--kill")
        self.assertNotEqual(result.returncode,0)
        self.assertFalse((self.root / "kill-called").exists())

    def test_default_runtime_options_work_with_macos_bash(self):
        self.env.pop("EMACS_RUNTIME_DIRECTORY")
        for name in ("emacs-daemon-start.sh", "emacs-sandbox.sh"):
            result = self.run_wrapper(name)
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_unresponsive_socket_refuses_fresh_without_touching_files(self):
        self.env["FIXTURE_MODE"]="hang"
        (self.sandbox / "evidence").write_text("preserved")
        result = self.run_wrapper("emacs-sandbox.sh", "--fresh")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.sandbox / "evidence").read_text(), "preserved")
        self.assertFalse((self.root / "helper-args").exists())

    def test_first_provision_without_replace_flag_works(self):
        shutil.rmtree(str(self.sandbox))
        result = self.run_wrapper("emacs-sandbox.sh")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.sandbox / "init.el").exists())

    def test_fresh_uses_filtered_copy_and_preserves_previous(self):
        (self.source / "session-state.el").write_text("live fixture")
        (self.sandbox / "old-evidence").write_text("preserved")
        result = self.run_wrapper("emacs-sandbox.sh","--fresh")
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertFalse((self.sandbox / "session-state.el").exists())
        backups=list(self.root.glob("sandbox.previous-*"))
        self.assertEqual(len(backups),1)
        self.assertEqual((backups[0]/"old-evidence").read_text(),"preserved")


if __name__ == "__main__":
    unittest.main()
