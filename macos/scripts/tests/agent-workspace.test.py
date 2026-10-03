"""Focus/routing regressions, with the macOS command boundary substituted.

No test launches a real application or changes the user's desktop.
"""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / "agent-workspace.py"


class WorkspaceTest(unittest.TestCase):
    def setUp(self):
        self.assertTrue(SCRIPT.exists(), "agent workspace controller is missing")
        spec = importlib.util.spec_from_file_location("workspace", SCRIPT)
        self.m = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.m)
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.state = Path(self.tmp.name) / "return.json"
        self.m.STATE = Path(self.tmp.name)
        self.spaces = [
            {"id": 10, "index": 1, "display": 1, "label": "", "has-focus": True, "is-visible": True},
            {"id": 20, "index": 2, "display": 2, "label": "", "has-focus": False, "is-visible": True},
            {"id": 30, "index": 3, "display": 2, "label": "agent", "has-focus": False, "is-visible": False},
        ]
        self.windows = [
            {"id": 101, "pid": 1, "app": "Emacs", "space": 1, "has-focus": True, "subrole": "AXStandardWindow"},
            {"id": 201, "pid": 2, "app": "Brave Browser", "space": 1, "has-focus": False, "subrole": "AXStandardWindow"},
            {"id": 301, "pid": 3, "app": "Brave Browser", "space": 1, "has-focus": False, "subrole": "AXStandardWindow"},
        ]
        self.calls = []
        def yabai(*args, **kwargs):
            self.calls.append(args)
            if args == ("query", "--spaces"):
                return json.dumps(self.spaces)
            if args == ("query", "--windows"):
                return json.dumps(self.windows)
            return ""
        self.addCleanup(patch.stopall)
        patch.object(self.m, "yabai", side_effect=yabai).start()
        patch.object(self.m, "agent_pids", return_value={3}).start()

    def test_routing_leaves_personal_brave_and_main_emacs_alone(self):
        self.m.route()
        self.assertIn(("window", "301", "--space", "agent"), self.calls)
        self.assertFalse(any(c[:2] in [("window", "101"), ("window", "201")] for c in self.calls))
        self.assertFalse(any("--focus" in c for c in self.calls))

    def test_background_restore_handles_same_space_focus_theft(self):
        snapshot = self.m.snapshot()
        self.windows[0]["has-focus"] = False
        self.windows[2]["has-focus"] = True
        self.m.restore(snapshot, background=True)
        self.assertIn(("window", "--focus", "101"), self.calls)

    def test_background_restore_respects_user_switch_to_personal_app(self):
        snapshot = self.m.snapshot()
        self.windows[0]["has-focus"] = False
        self.windows[1]["has-focus"] = True
        self.m.restore(snapshot, background=True)
        self.assertFalse(any("--focus" in c for c in self.calls))

    def test_restore_repairs_other_monitor_without_switching_focus(self):
        snapshot = self.m.snapshot()
        self.spaces[1]["is-visible"] = False
        self.spaces[2]["is-visible"] = True
        self.m.restore(snapshot, background=True)
        self.assertIn(("display", "2", "--space", "2"), self.calls)

    def test_toggle_saves_origin_and_returns_to_exact_window(self):
        self.m.toggle(self.state)
        self.assertIn(("space", "--focus", "agent"), self.calls)
        self.spaces[0]["has-focus"] = False
        self.spaces[2]["has-focus"] = True
        self.windows[0]["has-focus"] = False
        self.windows[2]["has-focus"] = True
        self.m.toggle(self.state)
        self.assertIn(("window", "--focus", "101"), self.calls)

    def test_return_uses_stable_space_id_after_indices_change(self):
        snapshot = self.m.snapshot()
        self.windows = []
        self.spaces[0]["index"] = 7
        self.spaces[0]["has-focus"] = False
        self.spaces[2]["has-focus"] = True
        self.m.restore(snapshot)
        self.assertIn(("space", "--focus", "7"), self.calls)

    def test_profile_matching_is_exact_and_not_application_wide(self):
        profile = str(Path.home() / ".local/share/agent-browser")
        exe = "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser"
        self.assertTrue(self.m.owned_process(f"{exe} --user-data-dir={profile} --no-first-run"))
        self.assertFalse(self.m.owned_process(exe))
        self.assertFalse(self.m.owned_process(f"{exe} --user-data-dir={profile}-personal"))
        self.assertTrue(self.m.owned_process("/opt/emacs --fg-daemon=sandbox --init-directory /tmp/sandbox"))
        self.assertFalse(self.m.owned_process("/opt/emacs --fg-daemon=server"))

    def test_routing_can_be_limited_to_the_launching_browser(self):
        self.m.route(pids={99})
        self.assertFalse(any(c[0] == "window" for c in self.calls))

    def test_browser_endpoint_must_belong_to_agent_profile(self):
        from io import BytesIO
        patch.object(self.m.urllib.request, "urlopen", return_value=BytesIO(b'{"webSocketDebuggerUrl":"ws://localhost/test"}')).start()
        patch.object(self.m, "run", return_value="2").start()
        with self.assertRaises(RuntimeError):
            self.m.browser_ready()

    def test_browser_failure_does_not_fall_back_to_foreground_open(self):
        import subprocess
        calls = []
        def run(*args, **kwargs):
            calls.append(args)
            if str(args[0]).endswith("agent-browser-newtab"):
                raise subprocess.CalledProcessError(1, args)
            return ""
        patch.object(self.m, "run", side_effect=run).start()
        patch.object(self.m, "browser_ready", return_value=True).start()
        with self.assertRaises(subprocess.CalledProcessError):
            self.m.open_url("https://example.com")
        self.assertFalse(any(c[0] == "open" or "/json/new" in str(c) for c in calls))


if __name__ == "__main__":
    unittest.main()
