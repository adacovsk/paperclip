"""Signal-table tests for dispatch.py.  Run: python3 -m unittest agents/dispatcher/dispatch_test.py"""

import importlib.util
import sys
import unittest
from pathlib import Path

_spec = importlib.util.spec_from_file_location("dispatch", Path(__file__).with_name("dispatch.py"))
dispatch = importlib.util.module_from_spec(_spec)
sys.modules["dispatch"] = dispatch  # dataclasses resolve annotations through sys.modules
_spec.loader.exec_module(dispatch)

GitState, decide = dispatch.GitState, dispatch.decide
CLEAN = GitState(exists=True, ahead=2, head="a" * 40, changed=("src/x.rs",), merges_clean=True)


def parent(labels=("needs-build",), status="in_review", description=""):
    return {"identifier": "T-1", "title": "Thing", "status": status, "description": description,
            "labels": [{"id": n, "name": n} for n in labels], "updatedAt": "t"}


def child(title, status, created, key=None):
    return {"identifier": "T-9", "title": title, "status": status, "createdAt": created,
            "updatedAt": created, "dedupeKey": key}


class WorkerStage(unittest.TestCase):
    def test_committed_clean_tree_gets_a_review(self):
        self.assertEqual(decide(parent(), [], CLEAN).kind, "review")

    def test_dirty_tree_is_handed_off(self):
        self.assertEqual(decide(parent(), [], GitState(exists=True, dirty=True, ahead=1)).kind, "handoff")

    def test_no_commits_is_handed_off(self):
        self.assertEqual(decide(parent(), [], GitState(exists=True)).kind, "handoff")

    def test_chain_is_handed_off(self):
        self.assertEqual(decide(parent(description="Chain: 3 steps\n"), [], CLEAN).kind, "handoff")

    def test_missing_worktree_is_handed_off(self):
        self.assertEqual(decide(parent(), [], GitState(exists=False)).kind, "handoff")

    def test_non_stage_children_do_not_block(self):
        followup = child("Wire a follow-up", "blocked", "1")
        self.assertEqual(decide(parent(), [followup], CLEAN).kind, "review")


class ReviewerStage(unittest.TestCase):
    review = child("Review: T-1", "done", "1", "review")

    def test_open_review_is_skipped(self):
        self.assertEqual(decide(parent(), [child("Review: T-1", "in_review", "1", "review")], CLEAN).kind, "skip")

    def test_needs_build_gets_a_verify(self):
        self.assertEqual(decide(parent(), [self.review], CLEAN).kind, "verify")

    def test_data_only_touching_loaded_data_gets_a_verify(self):
        git = GitState(exists=True, ahead=1, changed=("assets/data/en/feats.json",))
        self.assertEqual(decide(parent(("data-only",)), [self.review], git).kind, "verify")

    def test_data_only_without_data_path_is_handed_off(self):
        git = GitState(exists=True, ahead=1, changed=("docs/x.md",))
        self.assertEqual(decide(parent(("data-only",)), [self.review], git).kind, "handoff")

    def test_unlabeled_touching_rust_gets_a_verify(self):
        self.assertEqual(decide(parent(()), [self.review], CLEAN).kind, "verify")

    def test_unlabeled_touching_nothing_cargo_reads_is_handed_off(self):
        git = GitState(exists=True, ahead=1, changed=("scripts/allowlist.txt", "docs/x.md"))
        self.assertEqual(decide(parent(()), [self.review], git).kind, "handoff")

    def test_label_line_in_the_body_counts(self):
        git = GitState(exists=True, ahead=1, changed=("docs/x.md",))
        body = parent((), description="What: x\n**Label**: needs-build\n")
        self.assertEqual(decide(body, [self.review], git).kind, "verify")

    def test_data_only_label_touching_rust_still_gets_a_verify(self):
        self.assertEqual(decide(parent(("data-only",)), [self.review], CLEAN).kind, "verify")

    def test_cancelled_review_is_handed_off(self):
        self.assertEqual(decide(parent(), [child("Review: T-1", "cancelled", "1", "review")], CLEAN).kind, "handoff")

    def test_open_pr_wins_over_a_re_review(self):
        stages = [child("Verify: T-1", "done", "1", "verify"), child("Review: T-1", "done", "2", "review")]
        self.assertEqual(decide(parent(), stages, CLEAN, pr_head="b" * 40).kind, "skip")

    def test_finished_verify_is_left_to_landing(self):
        stages = [self.review, child("Verify: T-1", "done", "2", "verify")]
        self.assertEqual(decide(parent(), stages, CLEAN).kind, "skip")

    def test_ci_fix_key_counts_as_a_verify(self):
        stages = [self.review, child("ci-fix: abc", "in_review", "2", "ci-fix")]
        self.assertEqual(decide(parent(), stages, CLEAN).kind, "skip")


class RebaseStage(unittest.TestCase):
    stages = [child("Verify: T-1", "done", "1", "verify"), child("Rebase task/T-1 onto origin/main", "in_review", "2")]

    def test_clean_rebase_gets_a_re_verify(self):
        self.assertEqual(decide(parent(), self.stages, CLEAN).kind, "reverify")

    def test_rebase_already_on_the_pr_only_closes(self):
        self.assertEqual(decide(parent(), self.stages, CLEAN, pr_head=CLEAN.head).kind, "close-rebase")

    def test_rebase_behind_a_stale_pr_re_verifies(self):
        self.assertEqual(decide(parent(), self.stages, CLEAN, pr_head="b" * 40).kind, "reverify")

    def test_still_conflicting_is_handed_off(self):
        git = GitState(exists=True, ahead=1, head="a" * 40, merges_clean=False)
        self.assertEqual(decide(parent(), self.stages, git).kind, "handoff")

    def test_blocked_parent_is_handed_off(self):
        # Clearing a block the Coordinator wrote is the Coordinator's call.
        self.assertEqual(decide(parent(status="blocked"), self.stages, CLEAN).kind, "handoff")

    def test_running_rebase_is_skipped(self):
        stages = [child("Rebase task/T-1 onto origin/main", "in_progress", "2")]
        self.assertEqual(decide(parent(), stages, CLEAN).kind, "skip")


class Holds(unittest.TestCase):
    def test_parses_only_the_waiting_form(self):
        self.assertEqual(dispatch.held_waiting_on("Held: waiting on AA-12 — files"), "AA-12")
        self.assertIsNone(dispatch.held_waiting_on("Held: operator — design call"))
        self.assertIsNone(dispatch.held_waiting_on("Needs operator merge; waiting on AA-12"))

    def test_a_re_hold_after_our_release_is_final(self):
        comments = [
            {"createdAt": "1", "body": "Held: waiting on AA-9 — not on main"},
            {"createdAt": "2", "body": "Released: AA-9 has an open PR.\n\n> Held: waiting on AA-9"},
            {"createdAt": "3", "body": "Held: waiting on AA-9 — still unmerged"},
        ]
        self.assertTrue(dispatch.overruled(comments, "AA-9"))

    def test_a_release_on_another_blocker_does_not_count(self):
        comments = [
            {"createdAt": "1", "body": "Released: AA-8 is done.\n\n> Held: waiting on AA-8"},
            {"createdAt": "2", "body": "Held: waiting on AA-9 — files"},
        ]
        self.assertFalse(dispatch.overruled(comments, "AA-9"))

    def test_a_first_hold_is_not_overruled(self):
        self.assertFalse(dispatch.overruled([{"createdAt": "1", "body": "Held: waiting on AA-9"}], "AA-9"))

    def test_resolution(self):
        self.assertIn("done", dispatch.hold_resolved({"identifier": "A-1", "status": "done"}, False))
        self.assertIn("open PR", dispatch.hold_resolved({"identifier": "A-1", "status": "in_review"}, True))
        self.assertIsNone(dispatch.hold_resolved({"identifier": "A-1", "status": "in_review"}, False))
        self.assertIsNone(dispatch.hold_resolved(None, True))


if __name__ == "__main__":
    unittest.main()
