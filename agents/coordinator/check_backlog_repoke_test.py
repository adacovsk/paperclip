"""Tests for check_backlog_repoke.py.  Run: python3 -m unittest agents/coordinator/check_backlog_repoke_test.py"""

import importlib.util
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

_spec = importlib.util.spec_from_file_location("backlog_repoke", Path(__file__).with_name("check_backlog_repoke.py"))
backlog_repoke = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(backlog_repoke)

NOW = datetime(2026, 10, 20, 12, 0, tzinfo=timezone.utc)
A, B = "a" * 40, "b" * 40


def decide(minutes_ago, then, now_sha, max_age_s=21600):
    last = None if minutes_ago is None else NOW - timedelta(minutes=minutes_ago)
    return backlog_repoke.decide(last, then, now_sha, NOW, max_age_s)


class Decide(unittest.TestCase):
    def test_main_unmoved_since_the_last_fire_skips(self):
        repoke, why = decide(30, A, A)
        self.assertFalse(repoke)
        self.assertIn("still aaaaaaaaa", why)

    def test_main_moved_re_pokes(self):
        self.assertTrue(decide(30, A, B)[0])

    def test_a_last_fire_past_the_age_bound_re_pokes_even_on_an_unmoved_main(self):
        repoke, why = decide(7 * 60, A, A)
        self.assertTrue(repoke)
        self.assertIn("7.0h ago", why)

    def test_no_earlier_fire_re_pokes(self):
        self.assertTrue(decide(None, None, A)[0])

    def test_an_unreadable_main_re_pokes(self):
        self.assertTrue(decide(30, None, A)[0])
        self.assertTrue(decide(30, A, None)[0])


if __name__ == "__main__":
    unittest.main()
