"""Decision tests for dedupe.py.  Run: python3 -m unittest agents/dispatcher/dedupe_test.py"""

import importlib.util
import sys
import unittest
from datetime import datetime, timezone
from pathlib import Path

_spec = importlib.util.spec_from_file_location("dedupe", Path(__file__).with_name("dedupe.py"))
dedupe = importlib.util.module_from_spec(_spec)
sys.modules["dedupe"] = dedupe
_spec.loader.exec_module(dedupe)

NOW = datetime(2026, 10, 11, tzinfo=timezone.utc)


def task(ident, title, status="blocked", created="2026-10-07T00:00:00Z", **extra):
    return {"identifier": ident, "title": title, "status": status, "createdAt": created,
            "updatedAt": created, **extra}


class SameWork(unittest.TestCase):
    def test_identical_titles_match_with_or_without_section(self):
        self.assertTrue(dedupe.same_work("§4.982 — Retire whirlwind.txt with a mobile hazard mechanic",
                                         "Retire whirlwind.txt with a mobile hazard mechanic"))

    def test_a_title_cut_mid_word_matches_its_full_form(self):
        self.assertTrue(dedupe.same_work(
            "§4.982 — Retire shadow_blend.txt and transparent.txt with a concealmen",
            "§4.982 — Retire shadow_blend.txt and transparent.txt with a concealment state payload (batch 14 of 29)"))

    def test_a_cut_batch_number_is_not_a_prefix_of_a_longer_one(self):
        self.assertFalse(dedupe.same_work("Retire the dragon riders from the monster files batch 1",
                                          "Retire the dragon riders from the monster files batch 10 of 29"))

    def test_different_batches_of_one_front_differ(self):
        self.assertFalse(dedupe.same_work("§4.983 — Add a thing; author x (batch 9 of 54)",
                                          "§4.983 — Add a thing; author x (batch 10 of 54)"))

    def test_different_sections_never_match(self):
        self.assertFalse(dedupe.same_work("§4.1028 — Author four level 3 monster templates",
                                          "§4.1031 — Author four level 3 monster templates"))

    def test_a_short_generic_prefix_does_not_match(self):
        self.assertFalse(dedupe.same_work("Fix the build", "Fix the build on main after the merge"))


class Candidates(unittest.TestCase):
    def test_stage_subtasks_are_not_candidates(self):
        self.assertFalse(dedupe.is_candidate(task("AA-2", "Verify: AA-1 something"), NOW))
        self.assertFalse(dedupe.is_candidate(task("AA-2", "Something", parentId="p"), NOW))

    def test_cancelled_is_not_live(self):
        self.assertFalse(dedupe.is_candidate(task("AA-2", "Something", status="cancelled"), NOW))


TITLE = "§4.982 — Retire mending_light.txt and channel_vitality.txt via a healing payload (batch 12 of 29)"


class Plan(unittest.TestCase):
    def test_the_most_advanced_copy_survives_and_unstarted_copies_are_cancelled(self):
        g = [task("AA-1", TITLE, "blocked", "2026-10-07T01:00:00Z"),
             task("AA-2", TITLE, "in_review", "2026-10-07T02:00:00Z"),
             task("AA-3", TITLE, "backlog", "2026-10-07T03:00:00Z")]
        keep, cancel, left = dedupe.plan(g, {})
        self.assertEqual(keep["identifier"], "AA-2")
        self.assertEqual([i["identifier"] for i in cancel], ["AA-1", "AA-3"])
        self.assertEqual(left, [])

    def test_a_tie_keeps_the_oldest_filing(self):
        g = [task("AA-1", TITLE, created="2026-10-07T01:00:00Z"), task("AA-2", TITLE, created="2026-10-07T02:00:00Z")]
        keep, cancel, _ = dedupe.plan(g, {})
        self.assertEqual((keep["identifier"], [i["identifier"] for i in cancel]), ("AA-1", ["AA-2"]))

    def test_commits_break_a_status_tie(self):
        g = [task("AA-1", TITLE, created="2026-10-07T01:00:00Z"), task("AA-2", TITLE, created="2026-10-07T02:00:00Z")]
        keep, cancel, _ = dedupe.plan(g, {"AA-2": 3})
        self.assertEqual((keep["identifier"], [i["identifier"] for i in cancel]), ("AA-2", ["AA-1"]))

    def test_a_copy_with_commits_is_left_alone(self):
        g = [task("AA-1", TITLE, "in_review"), task("AA-2", TITLE, "blocked", "2026-10-08T00:00:00Z")]
        keep, cancel, left = dedupe.plan(g, {"AA-2": 2})
        self.assertEqual((keep["identifier"], cancel, [i["identifier"] for i in left]), ("AA-1", [], ["AA-2"]))

    def test_an_assigned_or_running_copy_is_never_cancelled(self):
        g = [task("AA-1", TITLE, "in_review"), task("AA-2", TITLE, "blocked", assigneeAgentId="w"),
             task("AA-3", TITLE, "todo")]
        _, cancel, _ = dedupe.plan(g, {})
        self.assertEqual(cancel, [])

    def test_a_done_copy_survives(self):
        g = [task("AA-1", TITLE, "done"), task("AA-2", TITLE, "blocked", "2026-10-08T00:00:00Z")]
        keep, cancel, _ = dedupe.plan(g, {})
        self.assertEqual((keep["identifier"], [i["identifier"] for i in cancel]), ("AA-1", ["AA-2"]))

    def test_groups_join_three_filings_of_one_batch(self):
        g = dedupe.groups([task("AA-1", TITLE), task("AA-2", TITLE[:70], created="2026-10-07T02:00:00Z"),
                           task("AA-3", "Something unrelated entirely here today", created="2026-10-07T03:00:00Z"),
                           task("AA-4", TITLE.split("— ", 1)[1], created="2026-10-07T04:00:00Z")])
        self.assertEqual([[i["identifier"] for i in x] for x in g], [["AA-1", "AA-2", "AA-4"]])


class Repoint(unittest.TestCase):
    def test_a_hold_on_a_cancelled_copy_moves_to_the_survivor(self):
        out = dedupe.repoint("Held: until AA-10 opens its PR — one at a time\n\ndetail", {"AA-10": "AA-20"})
        self.assertTrue(out.startswith("Held: until AA-20 opens its PR — one at a time\n"))
        self.assertIn("AA-10 cancelled", out)

    def test_ids_are_matched_whole(self):
        self.assertIsNone(dedupe.repoint("Held: until AA-100 merges", {"AA-10": "AA-1"}))

    def test_a_non_hold_comment_is_left(self):
        self.assertIsNone(dedupe.repoint("Released: AA-10 is done.", {"AA-10": "AA-1"}))


if __name__ == "__main__":
    unittest.main()
