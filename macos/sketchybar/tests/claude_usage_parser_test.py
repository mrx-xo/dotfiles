#!/usr/bin/env python3

import importlib.util
import json
import pathlib
import subprocess
import unittest


PARSER_PATH = pathlib.Path(__file__).parents[1] / "plugins" / "claude_usage.py"


def load_parser():
    if not PARSER_PATH.exists():
        raise AssertionError("Claude usage parser is not implemented")
    spec = importlib.util.spec_from_file_location("claude_usage", PARSER_PATH)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class ClaudeUsageParserTest(unittest.TestCase):
    def test_splits_fable_from_the_primary_label_for_independent_styling(self):
        parser = load_parser()
        response = {
            "five_hour": {"utilization": 9.4, "resets_at": "2026-09-03T18:00:00Z"},
            "seven_day": {"utilization": 39.6, "resets_at": "2026-09-06T07:00:00Z"},
            "limits": [
                {
                    "kind": "session",
                    "group": "session",
                    "percent": 9.4,
                    "severity": "normal",
                    "resets_at": "2026-09-03T18:00:00Z",
                    "scope": None,
                },
                {
                    "kind": "weekly_all",
                    "group": "weekly",
                    "percent": 39.6,
                    "severity": "normal",
                    "resets_at": "2026-09-06T07:00:00Z",
                    "scope": None,
                },
                {
                    "kind": "model",
                    "group": "weekly",
                    "percent": 12.2,
                    "severity": "warning",
                    "resets_at": "2026-09-06T07:00:00Z",
                    "scope": {"model": {"display_name": "Claude Fable 5.1"}},
                },
            ],
            "extra_usage": {
                "is_enabled": True,
                "monthly_limit": 200,
                "used_credits": 0,
                "utilization": 0,
            },
        }

        self.assertEqual(
            parser.parse_usage(response),
            ("9% · 40%", "12% |", "warning"),
        )

    def test_omits_fable_segment_when_server_does_not_report_it(self):
        parser = load_parser()
        response = {
            "limits": [
                {"kind": "session", "group": "session", "percent": 9},
                {"kind": "weekly_all", "group": "weekly", "percent": 40},
                {
                    "kind": "model",
                    "group": "weekly",
                    "percent": 70,
                    "scope": {"model": {"display_name": "Claude Sonnet 5"}},
                },
            ]
        }

        self.assertEqual(
            parser.parse_usage(response),
            ("9% · 40% |", None, "normal"),
        )

    def test_falls_back_to_legacy_session_and_weekly_fields(self):
        parser = load_parser()
        response = {
            "five_hour": {"utilization": 9.4, "resets_at": "2026-09-03T18:00:00Z"},
            "seven_day": {"utilization": 39.6, "resets_at": "2026-09-06T07:00:00Z"},
        }

        self.assertEqual(
            parser.parse_usage(response),
            ("9% · 40% |", None, "normal"),
        )

    def test_uses_latest_desktop_history_sample_when_api_is_unavailable(self):
        parser = load_parser()
        self.assertTrue(
            hasattr(parser, "parse_history"),
            "desktop history parser is not implemented",
        )
        history = {
            "version": 2,
            "samples": [
                {"t": 1788450000000, "org": "org-a", "u": {"fh": 8, "sd": 39}},
                {"t": 1788450759913, "org": "org-a", "u": {"fh": 10, "sd": 40}},
            ],
        }

        self.assertEqual(
            parser.parse_history(history),
            ("10% · 40% |", None, "normal"),
        )

    def test_cli_preserves_the_empty_fable_field_for_shell_parsing(self):
        response = {
            "five_hour": {"utilization": 9},
            "seven_day": {"utilization": 40},
        }

        result = subprocess.run(
            ["python3", str(PARSER_PATH)],
            input=json.dumps(response),
            capture_output=True,
            check=False,
            text=True,
        )

        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "9% · 40% |\t-\tnormal\n")


if __name__ == "__main__":
    unittest.main()
