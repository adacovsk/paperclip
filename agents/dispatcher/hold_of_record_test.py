"""Tests for hold_of_record.py.  Run: python3 -m unittest agents/dispatcher/hold_of_record_test.py"""

import importlib.util
import sys
import unittest
from pathlib import Path

_spec = importlib.util.spec_from_file_location("hold_of_record", Path(__file__).with_name("hold_of_record.py"))
hor = importlib.util.module_from_spec(_spec)
sys.modules["hold_of_record"] = hor
_spec.loader.exec_module(hor)


def c(ts, body):
    return {"createdAt": ts, "body": body}


# The API's own order: newest first.
NEWEST_FIRST = [
    c("2026-01-03T00:00:00Z", "Held: until T-2 merges — builds on its seam"),
    c("2026-01-02T00:00:00Z", "Released hold. Quoted: \"Held: until T-1 opens its PR\"."),
    c("2026-01-01T00:00:00Z", "Held: until T-1 opens its PR — file contended"),
]


class HoldOfRecord(unittest.TestCase):
    def test_newest_held_is_chosen_from_a_newest_first_list(self):
        newest, held = hor.hold_of_record(NEWEST_FIRST)
        self.assertEqual(held["body"], NEWEST_FIRST[0]["body"])
        self.assertIs(newest, held)

    def test_list_order_does_not_matter(self):
        _, held = hor.hold_of_record(list(reversed(NEWEST_FIRST)))
        self.assertTrue(held["body"].startswith("Held: until T-2 merges"))

    def test_a_later_non_hold_comment_is_flagged(self):
        comments = [c("2026-01-04T00:00:00Z", "Facilitator correction: reverted my release")] + NEWEST_FIRST
        lines = hor.report("T-9", comments)
        self.assertIn("T-9 newest:      Facilitator correction: reverted my release", lines)
        self.assertIn("T-9 newest-held: Held: until T-2 merges — builds on its seam", lines)
        self.assertTrue(any("WARNING" in line for line in lines))

    def test_held_must_start_the_first_line(self):
        _, held = hor.hold_of_record([c("2026-01-01T00:00:00Z", "Released hold. Quoted: \"Held: x\"")])
        self.assertIsNone(held)

    def test_no_comments(self):
        self.assertEqual(hor.hold_of_record([]), (None, None))
        self.assertEqual(hor.report("T-9", [])[1], "T-9 newest-held: (none)")


if __name__ == "__main__":
    unittest.main()
