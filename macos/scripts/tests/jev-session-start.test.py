#!/usr/bin/env python3
"""Behavior tests for jev-session-start.sh."""

import json
import os
import stat
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "jev-session-start.sh"
HOOK = str(Path.home() / "src/jevwire/plugin/dist/hook.mjs")
FIXTURE_TOKEN = "fixture-typesafe-token"


class JevSessionStartTest(unittest.TestCase):
    def setUp(self):
        self.tempdir = tempfile.TemporaryDirectory()
        self.addCleanup(self.tempdir.cleanup)
        self.bin_dir = Path(self.tempdir.name) / "bin"
        self.bin_dir.mkdir()
        self.record_path = Path(self.tempdir.name) / "node-record.json"

    def write_executable(self, name, body):
        path = self.bin_dir / name
        path.write_text(textwrap.dedent(body).lstrip())
        path.chmod(path.stat().st_mode | stat.S_IXUSR)
        return path

    def wrapper_env(self):
        env = os.environ.copy()
        env["PATH"] = str(self.bin_dir) + os.pathsep + env["PATH"]
        env["JEV_TEST_RECORD"] = str(self.record_path)
        return env

    def install_common_fixtures(self):
        self.write_executable(
            "timeout",
            """
            #!/usr/bin/env python3
            import os
            import sys

            os.execvp(sys.argv[2], sys.argv[2:])
            """,
        )
        self.write_executable(
            "node",
            """
            #!/usr/bin/env python3
            import json
            import os
            import sys

            record = {
                "argv": sys.argv[1:],
                "key_present": "TYPESAFE_API_KEY" in os.environ,
                "key_matches": os.environ.get("TYPESAFE_API_KEY")
                == "fixture-typesafe-token",
                "stdin": sys.stdin.read(),
            }
            with open(os.environ["JEV_TEST_RECORD"], "w") as stream:
                json.dump(record, stream)
            """,
        )

    def install_success_fixtures(self):
        self.install_common_fixtures()
        self.write_executable(
            "secret",
            """
            #!/usr/bin/env python3
            import sys

            if sys.argv[1:] != ["typesafe-api-token"]:
                raise SystemExit(64)
            sys.stdout.write("fixture-typesafe-token\\n")
            """,
        )

    def install_missing_secret_fixtures(self):
        self.install_common_fixtures()
        self.write_executable(
            "secret",
            """
            #!/usr/bin/env python3
            raise SystemExit(1)
            """,
        )

    def test_injects_key_only_into_session_start_child(self):
        self.assertTrue(SCRIPT.exists(), "SessionStart wrapper is missing")
        self.install_success_fixtures()
        hook_input = '{"session_id":"fixture-session"}'

        result = subprocess.run(
            [str(SCRIPT)],
            input=hook_input,
            text=True,
            capture_output=True,
            env=self.wrapper_env(),
            check=False,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "")
        self.assertNotIn(FIXTURE_TOKEN, result.stderr)
        record = json.loads(self.record_path.read_text())
        self.assertEqual(record["argv"], [HOOK, "SessionStart"])
        self.assertTrue(record["key_matches"])
        self.assertEqual(record["stdin"], hook_input)

    def test_missing_key_fails_open_without_inheriting_a_stale_value(self):
        self.assertTrue(SCRIPT.exists(), "SessionStart wrapper is missing")
        self.install_missing_secret_fixtures()
        env = self.wrapper_env()
        env["TYPESAFE_API_KEY"] = "stale-inherited-value"

        result = subprocess.run(
            [str(SCRIPT)],
            input='{"session_id":"fixture-without-key"}',
            text=True,
            capture_output=True,
            env=env,
            check=False,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        record = json.loads(self.record_path.read_text())
        self.assertEqual(record["argv"], [HOOK, "SessionStart"])
        self.assertFalse(record["key_present"])

    @unittest.skipUnless(
        os.environ.get("JEV_TEST_REAL_SECRET") == "1",
        "set JEV_TEST_REAL_SECRET=1 to exercise the Keychain lookup",
    )
    def test_real_keychain_item_reaches_only_the_child_environment(self):
        self.assertTrue(SCRIPT.exists(), "SessionStart wrapper is missing")
        self.write_executable(
            "node",
            """
            #!/usr/bin/env python3
            import json
            import os
            import sys

            record = {
                "argv": sys.argv[1:],
                "key_present": bool(os.environ.get("TYPESAFE_API_KEY")),
                "stdin": sys.stdin.read(),
            }
            with open(os.environ["JEV_TEST_RECORD"], "w") as stream:
                json.dump(record, stream)
            """,
        )
        hook_input = '{"session_id":"live-keychain-check"}'

        result = subprocess.run(
            [str(SCRIPT)],
            input=hook_input,
            text=True,
            capture_output=True,
            env=self.wrapper_env(),
            check=False,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "")
        record = json.loads(self.record_path.read_text())
        self.assertEqual(record["argv"], [HOOK, "SessionStart"])
        self.assertTrue(record["key_present"])
        self.assertEqual(record["stdin"], hook_input)


if __name__ == "__main__":
    unittest.main()
