"""Decision tests for promote.py.  Run: python3 -m unittest agents/dispatcher/promote_test.py"""

import importlib.util
import sys
import unittest
from pathlib import Path

_spec = importlib.util.spec_from_file_location("promote", Path(__file__).with_name("promote.py"))
promote = importlib.util.module_from_spec(_spec)
sys.modules["promote"] = promote
_spec.loader.exec_module(promote)

Board, judge = promote.Board, promote.judge
CLEAN = (0, "")
ROADMAP = "- **§4.983** — batch\n- **§4.1007** — split\n"


def task(title="§4.983 — Add a thing", ident="AA-1"):
    return {"identifier": ident, "title": title}


BODY = "**Where**: `src/systems/foo.rs`, `assets/data/en/feats.json`.\n"


class Parsing(unittest.TestCase):
    def test_paths_are_backticked_files_and_dirs(self):
        body = "Edit `src/a.rs` and `types.rs` in `src/components/`; key `shield_block`; `docs/ROADMAP.md:4`."
        self.assertEqual(promote.candidate_paths(body), ["src/a.rs", "types.rs", "src/components/"])

    def test_removes_keys_reads_only_the_removes_clause(self):
        body = "Removes: `anoint_ally`, `blood_rising` (in `class-sorcerer.txt`). Files: `src/x.rs`."
        self.assertEqual(promote.removes_keys(body), ["anoint_ally", "blood_rising"])

    def test_bare_file_name_matches_any_directory(self):
        self.assertTrue(promote.touches("types.rs", "src/resources/ability_data/types.rs"))
        self.assertTrue(promote.touches("src/components/", "src/components/health.rs"))
        self.assertFalse(promote.touches("src/a.rs", "src/ab.rs"))


class Judge(unittest.TestCase):
    def board(self, **kw):
        return Board(roadmap=ROADMAP, **kw)

    def test_clean_candidate_is_promoted(self):
        self.assertEqual(judge(task(), BODY, self.board(), CLEAN, {}).action, "promote")

    def test_same_title_in_flight_is_cancelled_as_duplicate(self):
        v = judge(task(), BODY, self.board(), (1, "AA-9\tin_review\tsame title\tx\n"), {})
        self.assertEqual(v.action, "cancel")
        self.assertIn("AA-9", v.reason)

    def test_sibling_batches_still_in_backlog_do_not_block(self):
        v = judge(task(), BODY, self.board(), (1, "AA-9\tbacklog\tnames §4.983\tx\nAA-8\tdone\tnames §4.983\tx\n"), {})
        self.assertEqual(v.action, "promote")

    def test_a_sibling_batch_being_written_holds_until_it_opens_its_pr(self):
        v = judge(task(), BODY, self.board(writing={"AA-9"}), (1, "AA-9\tin_review\tnames §4.983\tx\n"), {})
        self.assertEqual((v.action, v.blocker, v.hold_kind), ("hold", "AA-9", "opens its PR"))

    def test_a_sibling_parked_on_a_conflict_does_not_hold(self):
        v = judge(task(), BODY, self.board(), (1, "AA-9\tin_review\tnames §4.983\tx\n"), {})
        self.assertEqual(v.action, "promote")

    def test_a_root_directory_is_not_an_edit_surface(self):
        body = "**Where**: `src/`, `src/components/`, `src/systems/foo.rs`.\n"
        board = self.board(in_flight={"src/other.rs": {"AA-2", "AA-3"}, "src/components/x.rs": {"AA-2", "AA-3"}})
        self.assertEqual(judge(task(), body, board, CLEAN, {}).action, "promote")

    def test_a_held_sibling_is_not_in_flight(self):
        v = judge(task(), BODY, self.board(), (1, "AA-9\tblocked\tnames §4.983\tx\n"), {})
        self.assertEqual(v.action, "promote")

    def test_same_title_still_in_backlog_is_left_to_the_coordinator(self):
        v = judge(task(), BODY, self.board(), (1, "AA-9\tbacklog\tsame title\tx\n"), {})
        self.assertEqual(v.action, "judgment")

    def test_unreadable_claims_leave_it_to_the_coordinator(self):
        self.assertEqual(judge(task(), BODY, self.board(), (2, ""), {}).action, "judgment")

    def test_every_removed_key_gone_from_main_cancels_as_superseded(self):
        body = BODY + "Removes: `verdant_rest`.\n"
        v = judge(task(), body, self.board(), CLEAN, {"verdant_rest": False})
        self.assertEqual(v.action, "cancel")
        self.assertIn("superseded", v.reason)

    def test_a_key_still_on_main_does_not_cancel(self):
        body = BODY + "Removes: `a_key`, `b_key`.\n"
        v = judge(task(), body, self.board(), CLEAN, {"a_key": False, "b_key": True})
        self.assertEqual(v.action, "promote")

    def test_a_key_a_live_task_also_removes_holds_until_it_merges(self):
        body = BODY + "Removes: `a_key`.\n"
        v = judge(task(), body, self.board(live_keys={"a_key": {"AA-7"}}), CLEAN, {"a_key": True})
        self.assertEqual((v.action, v.blocker, v.hold_kind), ("hold", "AA-7", "merges"))

    def test_stated_ordering_goes_to_the_coordinator(self):
        body = BODY + "After §4.984 batch 1 so bloodlines are selectable.\n"
        self.assertEqual(judge(task(), body, self.board(), CLEAN, {}).action, "judgment")

    def test_a_reference_to_an_open_task_goes_to_the_coordinator(self):
        body = BODY + "Builds on AA-13055.\n"
        self.assertEqual(judge(task(), body, self.board(), CLEAN, {}).action, "judgment")

    def test_a_reference_to_a_closed_task_is_history(self):
        body = BODY + "Follow-up to AA-13055.\n"
        self.assertEqual(judge(task(), body, self.board(), CLEAN, {}, {"AA-13055"}).action, "promote")

    def test_a_section_gone_from_the_roadmap_goes_to_the_coordinator(self):
        self.assertEqual(judge(task("§4.999 — Gone"), BODY, self.board(), CLEAN, {}).action, "judgment")

    def test_no_paths_goes_to_the_coordinator(self):
        self.assertEqual(judge(task(), "What: a thing.", self.board(), CLEAN, {}).action, "judgment")

    def test_contended_path_holds_until_a_writer_opens_its_pr(self):
        board = self.board(in_flight={"src/systems/foo.rs": {"AA-2", "AA-3"}})
        v = judge(task(), BODY, board, CLEAN, {})
        self.assertEqual((v.action, v.hold_kind), ("hold", "opens its PR"))
        self.assertIn(v.blocker, {"AA-2", "AA-3"})

    def test_one_writer_below_the_threshold_does_not_hold(self):
        board = self.board(in_flight={"src/systems/foo.rs": {"AA-2"}})
        self.assertEqual(judge(task(), BODY, board, CLEAN, {}).action, "promote")

    def test_a_split_waits_while_many_unlanded_branches_edit_its_file(self):
        title = "§4.1007 — Split src/resources/campaign_data.rs into a module"
        body = "**Where**: `src/resources/campaign_data.rs`.\n"
        unlanded = {"src/resources/campaign_data.rs": ["AA-4", "AA-5", "AA-6"]}
        v = judge(task(title), body, self.board(unlanded=unlanded), CLEAN, {})
        self.assertEqual((v.action, v.blocker, v.hold_kind), ("hold", "AA-4", "merges"))

    def test_a_split_with_few_unlanded_branches_is_promoted(self):
        title = "§4.1007 — Split src/resources/campaign_data.rs into a module"
        body = "**Where**: `src/resources/campaign_data.rs`.\n"
        unlanded = {"src/resources/campaign_data.rs": ["AA-4"]}
        self.assertEqual(judge(task(title), body, self.board(unlanded=unlanded), CLEAN, {}).action, "promote")

    def test_hold_line_is_in_the_release_condition_form(self):
        v = promote.Verdict("hold", "why", "AA-4", "merges")
        self.assertEqual(promote.hold_line(v), "Held: until AA-4 merges — why")


if __name__ == "__main__":
    unittest.main()
