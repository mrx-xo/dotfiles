#!/usr/bin/env python3
"""Tests for agent-pr's pure parts.  Run: python3 -I macos/scripts/tests/agent-pr.test.py"""
import importlib.machinery
import importlib.util
import os
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
_loader = importlib.machinery.SourceFileLoader("agent_pr", os.path.join(HERE, "..", "agent-pr"))
_spec = importlib.util.spec_from_loader("agent_pr", _loader)
ap = importlib.util.module_from_spec(_spec)
_loader.exec_module(ap)

HANDOFF = "## Intent\nWhy.\n\n## Decisions\n- A over B.\n\n## Evidence\n- Tested: x.\n"
ROUTE = {"steps": [{"path": "a.el", "side": "new", "line_start": 3, "line_end": 4, "title": "T", "body": "B"}]}


class Remote(unittest.TestCase):
    def test_forms(self):
        self.assertEqual(ap.parse_remote("git@github.com:mrx-xo/dotfiles.git"), ("github.com", "mrx-xo", "dotfiles"))
        self.assertEqual(ap.parse_remote("https://github.com/o/r"), ("github.com", "o", "r"))
        self.assertEqual(ap.parse_remote("https://github.com/o/r.git/"), ("github.com", "o", "r"))
        self.assertEqual(ap.parse_remote("ssh://git@forge.example:2222/team/repo.git"), ("forge.example", "team", "repo"))
        self.assertEqual(ap.parse_remote("git@forge.example:team/repo.git"), ("forge.example", "team", "repo"))

    def test_garbage(self):
        with self.assertRaises(ap.Fail):
            ap.parse_remote("not a url")


class Handoff(unittest.TestCase):
    def test_ok(self):
        self.assertTrue(ap.check_handoff(HANDOFF).startswith("## Intent"))

    def test_missing_heading(self):
        with self.assertRaisesRegex(ap.Fail, "## Evidence"):
            ap.check_handoff("## Intent\nx\n## Decisions\ny\n")

    def test_comment_close(self):
        with self.assertRaises(ap.Fail):
            ap.check_handoff(HANDOFF + "oops -->")


class Route(unittest.TestCase):
    def test_ok(self):
        self.assertEqual(ap.check_route(ROUTE, {"a.el"}), ROUTE)
        self.assertEqual(ap.check_route(ROUTE, None), ROUTE)

    def test_bad(self):
        for bad, msg in [({}, "steps"), ({"steps": []}, "steps"),
                         ({"steps": [{"path": "a.el"}]}, "line_start"),
                         ({"steps": [{"path": "a.el", "line_start": 1, "title": "t", "side": "left"}]}, "side"),
                         ({"steps": [{"path": "a.el", "line_start": 1}]}, "title"),
                         ({"steps": [{"path": "z.el", "line_start": 1, "title": "t"}]}, "not changed")]:
            with self.subTest(bad=bad):
                with self.assertRaisesRegex(ap.Fail, msg):
                    ap.check_route(bad, {"a.el"})

    def test_comment_close_in_json(self):
        with self.assertRaises(ap.Fail):
            ap.check_route({"steps": [dict(ROUTE["steps"][0], body="x --> y")]}, None)


class Body(unittest.TestCase):
    def block(self, head="abc"):
        return ap.handoff_block(ap.check_handoff(HANDOFF), ROUTE, head)

    def test_block_shape(self):
        b = self.block("deadbeef")
        self.assertTrue(b.startswith("<details><summary>Review handoff</summary>"))
        self.assertIn("<!-- review-handoff v1 head=deadbeef\n{", b)
        self.assertTrue(b.endswith("-->\n</details>\n"))

    def test_new_body(self):
        body = ap.splice_body("", self.block(), "Fixes the thing.")
        self.assertTrue(body.startswith("Fixes the thing.\n\n<details>"))

    def test_update_keeps_human_text(self):
        old = "Edited by a human.\n\n" + self.block("old1") + "\nTrailing note."
        new = ap.splice_body(old, self.block("new2"), "ignored summary")
        self.assertIn("Edited by a human.", new)
        self.assertIn("Trailing note.", new)
        self.assertIn("head=new2", new)
        self.assertNotIn("head=old1", new)
        self.assertEqual(new.count("<details>"), 1)

    def test_update_without_block_appends(self):
        new = ap.splice_body("Old description.", self.block(), None)
        self.assertTrue(new.startswith("Old description.\n\n<details>"))


class Misc(unittest.TestCase):
    def test_notes_path(self):
        p = ap.notes_path({"git_dir": "/r/.git", "branch": "feat/x y"})
        self.assertEqual(p, "/r/.git/review-handoffs/notes/feat__x__y.md")

    def test_elisp_string(self):
        self.assertEqual(ap.elisp_string('a "b" \\c'), '"a \\"b\\" \\\\c"')


if __name__ == "__main__":
    unittest.main(verbosity=1)
