"""Signal-table tests for dispatch.py.  Run: python3 -m unittest agents/dispatcher/dispatch_test.py"""

import contextlib
from datetime import datetime, timezone
import io
import json
import importlib.util
import os
import subprocess
import tempfile
import time
import sys
import unittest
import urllib.error
from unittest import mock
from pathlib import Path

_spec = importlib.util.spec_from_file_location("dispatch", Path(__file__).with_name("dispatch.py"))
dispatch = importlib.util.module_from_spec(_spec)
sys.modules["dispatch"] = dispatch  # dataclasses resolve annotations through sys.modules
_spec.loader.exec_module(dispatch)

GitState, decide, iso_ts = dispatch.GitState, dispatch.decide, dispatch.iso_ts
CLEAN = GitState(exists=True, ahead=2, head="a" * 40, changed=("src/x.rs",), merges_clean=True)


def parent(labels=("needs-build",), status="in_review", description=""):
    return {"identifier": "T-1", "title": "Thing", "status": status, "description": description,
            "labels": [{"id": n, "name": n} for n in labels], "updatedAt": "t"}


def child(title, status, created, key=None):
    return {"id": f"{title}@{created}", "identifier": "T-9", "title": title, "status": status, "createdAt": created,
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

    def test_chain_mid_line_in_emphasis_is_handed_off(self):
        body = "- **Add the feature.** **Chain: 3 steps** (see the plan).\n"
        self.assertEqual(decide(parent(description=body), [], CLEAN).kind, "handoff")

    def test_chain_with_emphasis_on_the_word_alone_is_handed_off(self):
        body = "- **Label**: `needs-build`. **Priority**: medium. **Chain**: 2 steps.\n"
        self.assertEqual(decide(parent(description=body), [], CLEAN).kind, "handoff")

    def test_chain_step_trailer_is_not_a_chain_marker(self):
        self.assertEqual(decide(parent(description="Chain-step: 1\n"), [], CLEAN).kind, "review")

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

    def test_an_open_pr_that_conflicts_with_main_is_owed_a_fresh_verify(self):
        stages = [self.review, child("Verify: T-1", "done", "2", "verify")]
        conflicted = GitState(exists=True, ahead=2, head="a" * 40, changed=("src/x.rs",), conflicts=("src/x.rs",))
        decision = decide(parent(), stages, conflicted, pr_head="a" * 40)
        self.assertEqual((decision.kind, decision.reason), ("verify", dispatch.PR_CONFLICT))

    def test_a_schema_only_conflict_on_an_open_pr_is_reverified_too(self):
        stages = [self.review, child("Verify: T-1", "done", "2", "verify")]
        schemas = GitState(exists=True, ahead=2, changed=("src/x.rs",), conflicts=("assets/schemas/a.schema.json",))
        self.assertEqual(decide(parent(), stages, schemas, pr_head="a" * 40).reason, dispatch.PR_CONFLICT)

    def test_a_conflicting_open_pr_is_left_alone_when_it_cannot_be_resolved_here(self):
        stages = [self.review, child("Verify: T-1", "done", "2", "verify")]
        base = dict(exists=True, ahead=2, changed=("src/x.rs",), conflicts=("src/x.rs",))
        for git, who in (
            (GitState(**base, dirty=True), "a dirty tree is someone's unfinished edit"),
            (GitState(**base, deleted_on_main=True), "modify/delete is re-filed"),
        ):
            self.assertEqual(decide(parent(), stages, git, pr_head="a" * 40).reason, "PR open", who)
        held = decide(parent(status="blocked"), stages, GitState(**base), pr_head="a" * 40)
        self.assertEqual(held.reason, "PR open", "a blocked parent carries someone's hold")

    def test_a_conflicting_open_pr_goes_to_the_coordinator_past_the_cap(self):
        verifies = [child(f"Verify: T-1 #{n}", "done", str(n + 2), "verify") for n in range(dispatch.MAX_REBASES + 1)]
        conflicted = GitState(exists=True, ahead=2, changed=("src/x.rs",), conflicts=("src/x.rs",))
        self.assertEqual(decide(parent(), [self.review, *verifies], conflicted, pr_head="a" * 40).kind, "handoff")

    def test_clearing_the_landed_result_leaves_the_landed_marker(self):
        with tempfile.TemporaryDirectory() as tmp, mock.patch.object(dispatch, "VERIFY_DIR", Path(tmp)):
            for ext in ("exit", "cloud.resolve", "landed"):
                (Path(tmp) / f"T-1.{ext}").write_text("0")
            dispatch.clear_landed_result("T-1")
            dispatch.clear_landed_result("T-1")
            self.assertEqual(sorted(p.name for p in Path(tmp).iterdir()), ["T-1.landed"])

    def test_a_verify_whose_pr_merged_is_left_to_the_merge_sweep(self):
        stages = [self.review, child("Verify: T-1", "done", "2", "verify")]
        self.assertEqual(decide(parent(), stages, CLEAN, pr_merged=True).kind, "skip")

    def test_a_verify_closed_done_with_no_pr_is_owed_a_fresh_verify(self):
        stages = [self.review, child("Verify: T-1", "done", "2", "verify")]
        decision = decide(parent(), stages, CLEAN)
        self.assertEqual((decision.kind, decision.reason), ("verify", "verify closed done with no PR; a fresh verify is owed"))
        self.assertIs(dispatch.unlanded_verify(dispatch.ordered_stages(stages)), stages[1])

    def test_a_second_verify_closed_done_with_no_pr_is_handed_off(self):
        stages = [self.review, child("Verify: T-1", "done", "2", "verify"), child("Verify: T-1", "done", "3", "verify")]
        decision = decide(parent(), stages, CLEAN)
        self.assertEqual((decision.kind, decision.reason), ("handoff", "2 verifies closed done with no PR"))

    def test_an_unlanded_verify_with_nothing_to_land_is_handed_off(self):
        stages = [self.review, child("Verify: T-1", "done", "2", "verify")]
        empty = GitState(exists=True, ahead=0, merges_clean=True)
        self.assertEqual(decide(parent(), stages, empty).kind, "handoff")
        dirty = GitState(exists=True, ahead=2, dirty=True, merges_clean=True)
        self.assertEqual(decide(parent(), stages, dirty).kind, "handoff")

    def test_an_unlanded_verify_on_a_chain_with_steps_left_is_handed_off(self):
        stages = [self.review, child("Verify: T-1", "done", "2", "verify")]
        git = GitState(exists=True, ahead=2, merges_clean=True, chain_steps=1)
        self.assertEqual(decide(parent(description="Chain: 2 steps"), stages, git).kind, "handoff")

    def cancelled_verify(self, at="2026-10-18T00:58:00Z"):
        return [self.review, {**child("Verify: T-1", "cancelled", "2", "verify"), "cancelledAt": at}]

    def test_a_cancelled_final_verify_sends_the_parent_back_for_rework(self):
        git = GitState(exists=True, ahead=2, merges_clean=True, head_at=iso_ts("2026-10-17T00:00:00Z"))
        self.assertEqual(decide(parent(), self.cancelled_verify(), git).kind, "rework")

    def test_rework_committed_after_the_cancel_gets_a_review(self):
        git = GitState(exists=True, ahead=3, merges_clean=True, head_at=iso_ts("2026-10-19T00:00:00Z"))
        self.assertEqual(decide(parent(), self.cancelled_verify(), git).kind, "review")

    def test_chain_rework_with_steps_left_is_handed_off_not_reviewed(self):
        git = GitState(exists=True, ahead=3, merges_clean=True, head_at=iso_ts("2026-10-19T00:00:00Z"), chain_steps=2)
        decision = decide(parent(description="**Chain: 3 steps**"), self.cancelled_verify(), git)
        self.assertEqual((decision.kind, decision.reason), ("handoff", "chain task, 2 of 3 steps committed"))

    def test_chain_rework_with_every_step_committed_gets_its_review(self):
        git = GitState(exists=True, ahead=3, merges_clean=True, head_at=iso_ts("2026-10-19T00:00:00Z"), chain_steps=3)
        self.assertEqual(decide(parent(description="Chain: 3 steps"), self.cancelled_verify(), git).kind, "review")

    def test_a_reviewed_chain_with_steps_left_is_not_verified(self):
        git = GitState(exists=True, ahead=3, merges_clean=True, changed=("src/x.rs",), chain_steps=1)
        self.assertEqual(decide(parent(description="Chain: 2 steps"), [self.review], git).kind, "handoff")

    def test_rework_on_a_dirty_tree_is_handed_off(self):
        git = GitState(exists=True, dirty=True, ahead=3, head_at=iso_ts("2026-10-19T00:00:00Z"))
        self.assertEqual(decide(parent(), self.cancelled_verify(), git).kind, "handoff")

    def test_a_cancelled_verify_followed_by_another_stage_is_not_a_ruling(self):
        stages = [*self.cancelled_verify(), child("Verify: T-1", "done", "3", "verify")]
        self.assertEqual(decide(parent(), stages, CLEAN, pr_merged=True).kind, "skip")

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


CONFLICTED = GitState(exists=True, ahead=2, head="a" * 40, conflicts=("src/x.rs",))
VERIFY_BLOCKED = child("Verify: T-1", "blocked", "1", "verify")
REBASE_DONE = child("Rebase task/T-1 onto origin/main", "in_review", "2")


class SupersededStages(unittest.TestCase):
    def test_a_blocked_verify_does_not_hold_back_its_finished_rebase(self):
        self.assertEqual(decide(parent(), [VERIFY_BLOCKED, REBASE_DONE], CLEAN).kind, "reverify")

    def test_a_blocked_review_resumes_instead_of_a_verify(self):
        review = child("Review: T-1", "blocked", "1", "review")
        self.assertEqual(decide(parent(), [review, REBASE_DONE], CLEAN).kind, "resume-review")

    def test_a_stage_opened_after_the_rebase_still_counts(self):
        later = child("Verify: T-1", "blocked", "3", "verify")
        self.assertEqual(decide(parent(), [REBASE_DONE, later], CONFLICTED).kind, "rebase")
        running = child("Verify: T-1", "in_review", "3", "verify")
        self.assertEqual(decide(parent(), [REBASE_DONE, running], CLEAN).kind, "skip")

    def test_a_running_rebase_still_holds_the_parent(self):
        running = child("Rebase task/T-1 onto origin/main", "todo", "2")
        self.assertEqual(decide(parent(), [VERIFY_BLOCKED, running], CLEAN).kind, "skip")


    def test_a_rebase_closed_by_hand_still_re_verifies(self):
        closed = child("Rebase task/T-1 onto origin/main", "done", "2")
        self.assertEqual(decide(parent(), [VERIFY_BLOCKED, closed], CLEAN).kind, "reverify")

    def test_a_closed_rebase_with_nothing_blocked_is_history(self):
        verify = child("Verify: T-1", "done", "1", "verify")
        closed = child("Rebase task/T-1 onto origin/main", "done", "2")
        self.assertNotEqual(decide(parent(), [verify, closed], CLEAN).kind, "reverify")

    def test_a_resumed_review_that_finished_gets_a_verify(self):
        review = child("Review: T-1", "done", "1", "review")
        closed = child("Rebase task/T-1 onto origin/main", "done", "2")
        self.assertEqual(decide(parent(), [review, closed], CLEAN).kind, "verify")

    def test_a_cancelled_parent_is_left_alone(self):
        self.assertEqual(decide(parent(status="cancelled"), [VERIFY_BLOCKED, REBASE_DONE], CLEAN).kind, "skip")

    def test_a_resumed_review_changes_its_assignee_so_the_reviewer_wakes(self):
        class Recorder:
            def __init__(self):
                self.writes = []

            def get(self, path):
                return []

            def write(self, method, path, body, what):
                self.writes.append(body)

            set_status = dispatch.Api.set_status

        api = Recorder()
        review = child("Review: T-1", "blocked", "1", "review")
        stages = dispatch.ordered_stages([review, REBASE_DONE])
        dispatch.retire_superseded(api, {"Reviewer": "rev"}, stages, REBASE_DONE, resume=True)
        assignees = [w["assigneeAgentId"] for w in api.writes if "assigneeAgentId" in w]
        self.assertEqual(assignees, [None, "rev"])


class RebaseDispatch(unittest.TestCase):
    def test_a_verify_blocked_on_a_conflict_gets_a_rebase(self):
        d = decide(parent(), [VERIFY_BLOCKED], CONFLICTED)
        self.assertEqual((d.kind, d.reason), ("rebase", "src/x.rs"))

    def test_a_rebased_branch_main_moved_past_gets_another(self):
        self.assertEqual(decide(parent(), [VERIFY_BLOCKED, REBASE_DONE], CONFLICTED).kind, "rebase")

    def test_the_cap_hands_off_to_the_operator(self):
        used = [child("Rebase task/T-1 onto origin/main", "done", str(i)) for i in range(2, 2 + dispatch.MAX_REBASES)]
        last = child("Rebase task/T-1 onto origin/main", "in_review", "9")
        self.assertEqual(decide(parent(), [VERIFY_BLOCKED, *used[1:], last], CONFLICTED).kind, "handoff")

    def test_schema_only_conflicts_are_not_rebased(self):
        git = GitState(exists=True, ahead=1, conflicts=("assets/schemas/feats.schema.json",))
        self.assertEqual(decide(parent(), [VERIFY_BLOCKED], git).kind, "skip")

    def test_schema_paths_are_left_out_of_the_task(self):
        git = GitState(exists=True, ahead=1, conflicts=("assets/schemas/a.json", "src/x.rs"))
        self.assertEqual(decide(parent(), [VERIFY_BLOCKED], git).reason, "src/x.rs")

    def test_modify_delete_is_not_rebased(self):
        git = GitState(exists=True, ahead=1, conflicts=("src/x.rs",), deleted_on_main=True)
        self.assertEqual(decide(parent(), [VERIFY_BLOCKED], git).kind, "skip")

    def test_a_blocked_parent_keeps_its_hold(self):
        self.assertEqual(decide(parent(status="blocked"), [VERIFY_BLOCKED], CONFLICTED).kind, "skip")

    def test_a_worker_returned_rebase_blocked_is_not_retried(self):
        gave_up = child("Rebase task/T-1 onto origin/main", "blocked", "2")
        self.assertNotEqual(decide(parent(), [VERIFY_BLOCKED, gave_up], CONFLICTED).kind, "rebase")

    def test_parses_merge_tree_name_only(self):
        out = ("abc123\nsrc/x.rs\nsrc/x.rs\nsrc/y.rs\n\nAuto-merging src/x.rs\n"
               "CONFLICT (content): Merge conflict in src/x.rs\n")
        self.assertEqual(dispatch.parse_merge_tree(out), (("src/x.rs", "src/y.rs"), ()))
        out = "abc\nsrc/z.rs\n\nCONFLICT (modify/delete): src/z.rs deleted in origin/main and modified in HEAD.\n"
        self.assertEqual(dispatch.parse_merge_tree(out), (("src/z.rs",), ("src/z.rs",)))

    def test_a_module_split_on_main_is_ported(self):
        git = GitState(exists=True, ahead=1, conflicts=("src/x.rs",), split_on_main=("src/x.rs",))
        self.assertEqual(decide(parent(), [VERIFY_BLOCKED], git).kind, "rebase")
        self.assertEqual(dispatch.split_dir("src/a/b.rs"), "src/a/b")
        self.assertEqual(dispatch.split_dir("scripts/gen/profiles.py"), "scripts/gen/profiles")
        self.assertIsNone(dispatch.split_dir("assets/a.json"))


class Holds(unittest.TestCase):
    def test_a_re_hold_waits_out_an_open_pr_but_not_a_closed_blocker(self):
        open_pr = {"AA-9": {"identifier": "AA-9", "status": "in_review"}}
        self.assertIn("PR", dispatch.hold_release(("AA-9",), "pr", open_pr, {"AA-9"}, re_held=False))
        self.assertIsNone(dispatch.hold_release(("AA-9",), "pr", open_pr, {"AA-9"}, re_held=True))
        merged = {"AA-9": {"identifier": "AA-9", "status": "done"}}
        self.assertEqual(dispatch.hold_release(("AA-9",), "pr", merged, set(), re_held=True), "AA-9 is done")

    def test_a_hold_on_several_blockers_waits_for_every_one(self):
        blockers = {"AA-1": {"identifier": "AA-1", "status": "done"}, "AA-2": {"identifier": "AA-2", "status": "in_review"}}
        self.assertIsNone(dispatch.hold_release(("AA-1", "AA-2"), "merge", blockers, set(), re_held=False))
        self.assertIsNone(dispatch.hold_release(("AA-1", "AA-3"), "merge", blockers, set(), re_held=False))
        blockers["AA-2"]["status"] = "cancelled"
        self.assertEqual(
            dispatch.hold_release(("AA-1", "AA-2"), "merge", blockers, set(), re_held=False),
            "AA-1 is done; AA-2 is cancelled",
        )

    def test_merge_hold_waits_for_the_merge(self):
        in_review = {"identifier": "A-1", "status": "in_review"}
        self.assertIsNone(dispatch.hold_resolved(in_review, "merge", True))
        self.assertIn("done", dispatch.hold_resolved({"identifier": "A-1", "status": "done"}, "merge", False))

    def test_pr_hold_releases_on_the_pr(self):
        in_review = {"identifier": "A-1", "status": "in_review"}
        self.assertIn("PR", dispatch.hold_resolved(in_review, "pr", True))
        self.assertIsNone(dispatch.hold_resolved(in_review, "pr", False))
        self.assertIsNone(dispatch.hold_resolved(None, "pr", True))



class UnheldEscalations(unittest.TestCase):
    """A blocked stage nobody owns is routed to the Planner with its own reason."""

    VERIFY = {"id": "v", "identifier": "AA-20"}

    STAGE_AGENTS = {"arch", "rev"}

    @staticmethod
    def comment(at, body, author="arch"):
        return {"createdAt": at, "body": body, "authorAgentId": author}

    def test_a_requeue_note_is_not_an_escalation(self):
        comments = [
            self.comment("1", "main does not compile; nothing here is this task's."),
            self.comment("2", "Requeued by requeue-base-red.sh: main moved past the break; the verify re-dispatched.", None),
        ]
        self.assertIsNone(dispatch.unheld_escalation(self.VERIFY, "AA-2", comments, True, set(), self.STAGE_AGENTS))

    def test_another_agents_note_is_not_an_escalation(self):
        comments = [self.comment("1", "Handing to the Architect: its verify result needs a model.", "disp")]
        self.assertIsNone(dispatch.unheld_escalation(self.VERIFY, "AA-2", comments, True, set(), self.STAGE_AGENTS))

    def test_a_marked_escalation_routes_whoever_posted_it(self):
        comments = [self.comment("1", "Red twice.\n\nPAPERCLIP-ESCALATE: pick a scope", None)]
        self.assertEqual(
            dispatch.unheld_escalation(self.VERIFY, "AA-2", comments, True, set(), self.STAGE_AGENTS),
            "AA-20 escalated: pick a scope",
        )

    def test_a_stage_re_dispatched_since_it_was_read_is_not_routed(self):
        class Api:
            def __init__(self, fresh):
                self.fresh = fresh

            def get(self, path):
                return self.fresh

        read = {"id": "v", "status": "blocked", "assigneeAgentId": "arch"}
        self.assertTrue(dispatch.still_parked(Api({"status": "blocked", "assigneeAgentId": "arch"}), read))
        self.assertFalse(dispatch.still_parked(Api({"status": "todo", "assigneeAgentId": "arch"}), read))
        self.assertFalse(dispatch.still_parked(Api({"status": "blocked", "assigneeAgentId": "planner"}), read))

    def test_routes_a_marked_escalation_with_its_reason(self):
        comments = [self.comment("2", "Two worn-item tests fail.\n\nPAPERCLIP-ESCALATE: pick a scope for the Epaulet slot")]
        self.assertEqual(
            dispatch.unheld_escalation(self.VERIFY, "AA-2", comments, True, set(), self.STAGE_AGENTS),
            "AA-20 escalated: pick a scope for the Epaulet slot",
        )

    def test_routes_a_prose_escalation_by_its_first_line(self):
        comments = [self.comment("2", "What it needs: an operator to land it.\nDetail follows.")]
        self.assertEqual(
            dispatch.unheld_escalation(self.VERIFY, "AA-2", comments, True, set(), self.STAGE_AGENTS),
            "AA-20 escalated: What it needs: an operator to land it.",
        )

    def test_a_held_stage_is_owned(self):
        comments = [self.comment("1", "PAPERCLIP-ESCALATE: x")]
        held = {**self.VERIFY, "hold": {"kind": "operator", "blockers": [], "note": "needs a ruling"}}
        self.assertIsNone(dispatch.unheld_escalation(held, "AA-2", comments, True, set(), self.STAGE_AGENTS))

    def test_a_conflict_is_the_rebase_lanes(self):
        comments = [self.comment("1", "PAPERCLIP-ESCALATE: conflict with main")]
        self.assertIsNone(dispatch.unheld_escalation(self.VERIFY, "AA-2", comments, False, set(), self.STAGE_AGENTS))

    def test_a_red_main_is_the_base_red_markers_by_stage_or_parent(self):
        comments = [self.comment("1", "PAPERCLIP-ESCALATE: main does not compile")]
        self.assertIsNone(dispatch.unheld_escalation(self.VERIFY, "AA-2", comments, True, {"AA-20"}, self.STAGE_AGENTS))
        self.assertIsNone(dispatch.unheld_escalation(self.VERIFY, "AA-2", comments, True, {"AA-2"}, self.STAGE_AGENTS))

    def test_a_stage_with_no_comment_is_left(self):
        self.assertIsNone(dispatch.unheld_escalation(self.VERIFY, "AA-2", [], True, set(), self.STAGE_AGENTS))

    PARKED = {**VERIFY, "assigneeAgentId": "arch"}

    def test_a_stage_parked_on_its_agent_routes_past_an_operator_remark(self):
        comments = [
            self.comment("1", "Two lib tests fail outside this task's files.\nDetail follows."),
            {"createdAt": "2", "body": "Operator: looked at this, not mine to rule on.", "authorAgentId": None,
             "authorUserId": "op"},
        ]
        self.assertEqual(
            dispatch.unheld_escalation(self.PARKED, "AA-2", comments, True, set(), self.STAGE_AGENTS),
            "AA-20 escalated: Two lib tests fail outside this task's files.",
        )
        # Unassigned, the same thread is no escalation: the stage agent did not park it.
        self.assertIsNone(dispatch.unheld_escalation(self.VERIFY, "AA-2", comments, True, set(), self.STAGE_AGENTS))

    def test_a_stage_parked_on_its_agent_with_no_comment_is_routed(self):
        self.assertIn("no `Held:` line",
                      dispatch.unheld_escalation(self.PARKED, "AA-2", [], True, set(), self.STAGE_AGENTS))

    def test_a_dispatcher_note_after_the_park_still_wins(self):
        # A relaunch leaves the Verify blocked on the Architect while its build is out.
        comments = [
            self.comment("1", "Red on a test outside this task."),
            self.comment("2", "Relaunched by the Dispatcher, no model run: stale result.", "disp"),
        ]
        self.assertIsNone(dispatch.unheld_escalation(self.PARKED, "AA-2", comments, True, set(), self.STAGE_AGENTS))

    def test_a_parked_stage_keeps_its_other_owners(self):
        comments = [self.comment("1", "main does not compile")]
        held = {**self.PARKED, "hold": {"kind": "operator", "blockers": []}}
        self.assertIsNone(dispatch.unheld_escalation(held, "AA-2", comments, True, set(), self.STAGE_AGENTS))
        self.assertIsNone(dispatch.unheld_escalation(self.PARKED, "AA-2", comments, False, set(), self.STAGE_AGENTS))
        self.assertIsNone(dispatch.unheld_escalation(self.PARKED, "AA-2", comments, True, {"AA-20"}, self.STAGE_AGENTS))


class NothingToLand(unittest.TestCase):
    """A blocked stage on a branch with no net change goes to the Coordinator to close."""

    EMPTY = GitState(exists=True, ahead=2, head="a" * 40, merges_clean=True)

    def stages(self, last):
        return [child("Review: T-1", "done", "1", "review"), last]

    def test_a_blocked_verify_with_an_empty_diff_is_handed_off(self):
        decision = decide(parent(), self.stages(child("Verify: T-1", "blocked", "2", "verify")), self.EMPTY)
        self.assertEqual(decision.kind, "handoff")
        self.assertIn("nothing to land", decision.reason)

    def test_so_is_a_blocked_review(self):
        stages = [child("Review: T-1", "blocked", "1", "review")]
        self.assertEqual(decide(parent(), stages, GitState(exists=True, merges_clean=True)).kind, "handoff")

    def test_a_held_stage_keeps_its_hold(self):
        verify = {**child("Verify: T-1", "blocked", "2", "verify"), "hold": {"kind": "until_merge", "blockers": []}}
        self.assertEqual(decide(parent(), self.stages(verify), self.EMPTY).reason, dispatch.BLOCKED_STAGE)

    def test_a_dirty_tree_or_a_real_diff_is_not_nothing(self):
        stages = self.stages(child("Verify: T-1", "blocked", "2", "verify"))
        dirty = GitState(exists=True, ahead=2, dirty=True, merges_clean=True)
        self.assertEqual(decide(parent(), stages, dirty).reason, dispatch.BLOCKED_STAGE)
        self.assertEqual(decide(parent(), stages, CLEAN).reason, dispatch.BLOCKED_STAGE)


class OrphanStages(unittest.TestCase):
    """An open stage under a closed parent is cancelled, whatever closed the parent."""

    class Api:
        dry_run = False

        def __init__(self, open_issues, parents):
            self.open_issues, self.parents, self.writes, self.reads = open_issues, parents, [], []

        def issues(self, **query):
            return self.open_issues

        def get(self, path):
            pid = path.rsplit("/", 1)[1]
            self.reads.append(pid)
            return self.parents[pid]

        def set_status(self, issue, body, comment, what):
            self.writes.append((issue["identifier"], body["status"], comment))

    PARENTS = {
        "merged": {"identifier": "AA-1", "status": "done"},
        "dropped": {"identifier": "AA-2", "status": "cancelled"},
        "live": {"identifier": "AA-3", "status": "in_review"},
    }

    def test_cancels_stages_under_done_and_cancelled_parents_only(self):
        api = self.Api([
            {"id": "a", "identifier": "AA-11", "title": "Verify: AA-1 x", "parentId": "merged"},
            {"id": "b", "identifier": "AA-12", "title": "Rebase task/AA-2 onto origin/main", "parentId": "dropped"},
            {"id": "c", "identifier": "AA-13", "title": "Review: AA-3 x", "parentId": "live"},
            {"id": "d", "identifier": "AA-14", "title": "Follow-up: tidy AA-1", "parentId": "merged"},
            {"id": "e", "identifier": "AA-15", "title": "Verify: AA-9 x"},
        ], self.PARENTS)
        self.assertEqual(dispatch.cancel_orphan_stages(api), ["AA-11", "AA-12"])
        self.assertEqual([(w[0], w[1]) for w in api.writes], [("AA-11", "cancelled"), ("AA-12", "cancelled")])
        self.assertIn("parent AA-2 is `cancelled`", api.writes[1][2])

    def test_reads_each_parent_once(self):
        api = self.Api([
            {"id": "a", "identifier": "AA-11", "title": "Verify: AA-1 x", "parentId": "merged"},
            {"id": "b", "identifier": "AA-12", "title": "Review: AA-1 x", "parentId": "merged"},
        ], self.PARENTS)
        dispatch.cancel_orphan_stages(api)
        self.assertEqual(api.reads, ["merged"])

    def test_unanswered_parent_read_skips_only_its_stages(self):
        api = self.Api([
            {"id": "a", "identifier": "AA-11", "title": "Verify: AA-1 x", "parentId": "slow"},
            {"id": "b", "identifier": "AA-12", "title": "Review: AA-1 x", "parentId": "slow"},
            {"id": "c", "identifier": "AA-13", "title": "Rebase task/AA-2 onto origin/main", "parentId": "dropped"},
        ], self.PARENTS)

        def get(path, inner=api.get):
            if path.endswith("/slow"):
                api.reads.append("slow")
                raise dispatch.ApiUnreachable("GET /issues/slow: timed out")
            return inner(path)

        api.get = get
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(dispatch.cancel_orphan_stages(api), ["AA-13"])
        # The unanswered parent is not asked again for its second stage.
        self.assertEqual(api.reads, ["slow", "dropped"])

    def test_unanswered_cancel_skips_that_stage_only(self):
        api = self.Api([
            {"id": "a", "identifier": "AA-11", "title": "Verify: AA-1 x", "parentId": "merged"},
            {"id": "b", "identifier": "AA-12", "title": "Review: AA-1 x", "parentId": "merged"},
        ], self.PARENTS)

        def set_status(issue, body, comment, what, inner=api.set_status):
            if issue["identifier"] == "AA-11":
                raise dispatch.ApiUnreachable("PATCH: timed out")
            inner(issue, body, comment, what)

        api.set_status = set_status
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(dispatch.cancel_orphan_stages(api), ["AA-12"])


def hold(kind, *blockers, note=None, reheld=False):
    return {"kind": kind, "blockers": [{"id": b, "identifier": b} for b in blockers], "note": note, "reheld": reheld}


class ReleaseHolds(unittest.TestCase):
    """The release sweep reads each parked task's `hold`, and nothing from its comments."""

    class Api:
        dry_run = False

        def __init__(self, holds, statuses=None, titles=None):
            self.holds = holds
            self.statuses = statuses or {}
            self.titles = titles or {}
            self.writes = []
            self.reads = []

        def issues(self, **query):
            return [
                {"id": i, "identifier": f"AA-{i}", "title": self.titles.get(i, "Add a thing"), "status": "blocked", "hold": h}
                for i, h in self.holds.items()
            ]

        def get(self, path):
            self.reads.append(path)
            ident = path.split("/")[2]
            return {"identifier": ident, "status": self.statuses.get(ident, "in_review")}

        def set_status(self, issue, body, comment, what):
            self.writes.append((issue["identifier"], body, comment))

        def hold(self, issue, kind, what, blockers=(), note=None, **fields):
            self.writes.append((issue["identifier"], {**fields, "hold": {"kind": kind, "note": note}}, None))

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.saved = dispatch.STATE_DIR
        dispatch.STATE_DIR = Path(self.tmp.name)

    def tearDown(self):
        dispatch.STATE_DIR = self.saved
        self.tmp.cleanup()

    def test_a_planner_hold_is_assigned_to_the_planner_as_todo_with_the_hold_standing(self):
        api = self.Api({
            "1": hold("planner", note="no attacker-side seam"),
            "2": hold("operator", note="paperclip source fix"),
        })
        self.assertEqual(dispatch.release_holds(api, {}, {"Planner": "planner-id"}), 0)
        self.assertEqual(len(api.writes), 1)
        ident, body, _ = api.writes[0]
        self.assertEqual(ident, "AA-1")
        self.assertEqual(body["status"], "todo")
        self.assertEqual(body["assigneeAgentId"], "planner-id")
        self.assertEqual(body["hold"], {"kind": "planner", "note": "no attacker-side seam"})
        self.assertTrue(body["comment"].startswith("Held: planner — no attacker-side seam\n"))

    def test_a_planner_re_hold_on_a_release_condition_is_not_routed_back(self):
        api = self.Api({"1": hold("until_merge", "AA-7", note="files the seam")})
        dispatch.release_holds(api, {}, {"Planner": "planner-id"})
        self.assertEqual(api.writes, [])

    def test_a_met_hold_goes_back_to_backlog_and_no_comment_is_read(self):
        api = self.Api({"1": hold("until_merge", "AA-7", note="builds on its seam")}, {"AA-7": "done"})
        self.assertEqual(dispatch.release_holds(api, {}), 1)
        ident, body, comment = api.writes[0]
        self.assertEqual((ident, body), ("AA-1", {"status": "backlog"}))
        self.assertTrue(comment.startswith("Released: AA-7 is done."))
        self.assertIn("> Held until AA-7 merged — builds on its seam", comment)
        self.assertEqual(api.reads, ["/issues/AA-7"])

    def test_a_released_stage_goes_back_to_in_review_on_its_stage_agent(self):
        api = self.Api(
            {"1": hold("until_merge", "AA-7"), "2": hold("until_merge", "AA-7"), "3": hold("until_merge", "AA-7")},
            {"AA-7": "done"},
            {"1": "Verify: AA-5 x", "2": "Review: AA-6 y", "3": "ci-fix: AA-5 x"},
        )
        agents = {"Architect": "architect-id", "Reviewer": "reviewer-id"}
        self.assertEqual(dispatch.release_holds(api, {}, agents), 3)
        self.assertEqual([(w[0], w[1]) for w in api.writes], [
            ("AA-1", {"status": "in_review", "assigneeAgentId": "architect-id"}),
            ("AA-2", {"status": "in_review", "assigneeAgentId": "reviewer-id"}),
            ("AA-3", {"status": "in_review", "assigneeAgentId": "architect-id"}),
        ])

    def test_a_released_stage_with_no_stage_agent_on_the_roster_goes_to_backlog(self):
        api = self.Api({"1": hold("until_merge", "AA-7")}, {"AA-7": "done"}, {"1": "Verify: AA-5 x"})
        self.assertEqual(dispatch.release_holds(api, {}, {"Reviewer": "reviewer-id"}), 1)
        self.assertEqual(api.writes[0][1], {"status": "backlog"})

    def test_a_parked_task_with_no_hold_is_left(self):
        api = self.Api({"1": None})
        self.assertEqual(dispatch.release_holds(api, {}), 0)
        self.assertEqual(api.writes, [])

    def test_a_hold_naming_no_release_condition_is_reported(self):
        api = self.Api({"1": hold("other", note="until the nightly is green")})
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            self.assertEqual(dispatch.release_holds(api, {}), 0)
        self.assertEqual(api.writes, [])
        self.assertIn("name no release condition; left to the Coordinator: AA-1", out.getvalue())

    def test_a_pr_hold_releases_on_the_open_pr(self):
        api = self.Api({"1": hold("until_pr", "AA-7")})
        self.assertEqual(dispatch.release_holds(api, {"task/AA-7": "a" * 40}), 1)
        self.assertIn("AA-7 has opened its PR", api.writes[0][2])

    def test_a_re_hold_on_a_closed_blocker_is_released_whoever_wrote_it(self):
        api = self.Api({"1": hold("until_pr", "AA-7", note="3 live writers", reheld=True)}, {"AA-7": "done"})
        self.assertEqual(dispatch.release_holds(api, {}), 1)
        ident, body, comment = api.writes[0]
        self.assertEqual((ident, body), ("AA-1", {"status": "backlog"}))
        self.assertTrue(comment.startswith("Released: AA-7 is done."))

    def test_a_re_hold_on_a_blocker_with_its_pr_open_is_named_not_released(self):
        api = self.Api({"1": hold("until_pr", "AA-7", note="still contended", reheld=True)})
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            self.assertEqual(dispatch.release_holds(api, {"task/AA-7": "a" * 40}), 0)
        self.assertEqual(api.writes, [])
        self.assertIn("with the PR open, so held until the merge: AA-1", out.getvalue())

    def test_a_hold_on_several_blockers_waits_for_all_of_them(self):
        holds = {"1": hold("until_merge", "AA-7", "AA-8", note="one slice at a time")}
        self.assertEqual(dispatch.release_holds(self.Api(holds, {"AA-7": "done"}), {}), 0)
        dispatch.STATE_DIR.joinpath("holds.json").unlink(missing_ok=True)
        api = self.Api(holds, {"AA-7": "done", "AA-8": "cancelled"})
        self.assertEqual(dispatch.release_holds(api, {}), 1)
        self.assertIn("AA-7 is done; AA-8 is cancelled", api.writes[0][2])


class RoutineFire(unittest.TestCase):
    FIRE = {"originKind": "routine_execution", "assigneeAgentId": "me", "status": "todo"}

    def test_own_open_routine_issue_is_closed(self):
        self.assertTrue(dispatch.routine_fire(self.FIRE, "me"))

    def test_stage_completion_wake_is_not_a_fire(self):
        self.assertFalse(dispatch.routine_fire({**self.FIRE, "originKind": "manual"}, "me"))

    def test_another_agents_routine_is_left_alone(self):
        self.assertFalse(dispatch.routine_fire(self.FIRE, "coordinator"))

    def test_closed_issue_is_left_alone(self):
        self.assertFalse(dispatch.routine_fire({**self.FIRE, "status": "done"}, "me"))

    def test_no_task_is_not_a_fire(self):
        self.assertFalse(dispatch.routine_fire(None, "me"))


class OpenPrHeads(unittest.TestCase):
    """A draft opened when the verify launched is not a landing."""

    def test_drafts_are_not_open_prs(self):
        prs = [
            {"headRefName": "task/AA-1", "headRefOid": "aaa", "isDraft": True},
            {"headRefName": "task/AA-2", "headRefOid": "bbb", "isDraft": False},
        ]
        out = mock.Mock(stdout=json.dumps(prs))
        with mock.patch.object(dispatch.subprocess, "run", return_value=out) as run:
            heads = dispatch.open_pr_heads(Path("."))
        self.assertEqual(heads, {"task/AA-2": "bbb"})
        self.assertIn("isDraft", run.call_args.args[0][-1], "the draft flag has to be requested to be filtered")

    def test_branch_protection_counts_drafts(self):
        prs = [{"headRefName": "task/AA-1", "headRefOid": "aaa", "isDraft": True}]
        self.assertEqual(dispatch.open_pr_heads(Path("."), prs=prs, drafts=True), {"task/AA-1": "aaa"})
        self.assertEqual(dispatch.open_pr_heads(Path("."), prs=prs), {})

    def test_a_draft_train_pr_is_no_alias_for_its_task(self):
        prs = [{"headRefName": "train/3/AA-9", "headRefOid": "ccc", "isDraft": True, "state": "OPEN"}]
        self.assertEqual(dispatch.by_head(dispatch.ready_prs(prs), "headRefOid"), {})


class VerifyLanded(unittest.TestCase):
    VERIFY = {"status": "in_review", "createdAt": "2026-01-01T00:00:00.000Z"}
    HEAD = "b" * 40
    AFTER = dispatch.iso_ts("2026-01-01T01:00:00Z")
    BEFORE = dispatch.iso_ts("2025-12-31T23:00:00Z")

    def test_architect_landed_head_on_the_open_pr_closes_it(self):
        self.assertTrue(dispatch.verify_landed(self.VERIFY, self.HEAD, None, (self.HEAD, self.AFTER)))

    def test_merged_pr_closes_it_without_a_marker(self):
        self.assertTrue(dispatch.verify_landed(self.VERIFY, None, 7, None))

    def test_open_pr_without_a_marker_is_left(self):
        # A Verify re-dispatched onto a head that already has a PR looks like this.
        self.assertIsNone(dispatch.verify_landed(self.VERIFY, self.HEAD, None, None))

    def test_marker_older_than_the_verify_is_left(self):
        self.assertIsNone(dispatch.verify_landed(self.VERIFY, self.HEAD, None, (self.HEAD, self.BEFORE)))

    def test_pr_on_another_head_is_left(self):
        self.assertIsNone(dispatch.verify_landed(self.VERIFY, "c" * 40, None, (self.HEAD, self.AFTER)))

    def test_closed_verify_is_left(self):
        self.assertIsNone(dispatch.verify_landed({**self.VERIFY, "status": "blocked"}, None, 7, None))


class SupersededVerify(unittest.TestCase):
    VERIFY = {"status": "blocked", "createdAt": "2026-01-01T00:00:00Z"}
    BEFORE = dispatch.iso_ts("2025-12-31T00:00:00Z")
    AFTER = dispatch.iso_ts("2026-01-02T00:00:00Z")
    MARKER = "superseded-by: abc123 Merge pull request #7\noverlap: src/a.rs\nsrc/a.rs:2 does it\n"

    def test_a_confirmed_marker_closes_a_blocked_verify(self):
        evidence = dispatch.superseded_evidence(self.VERIFY, (self.MARKER, self.AFTER))
        self.assertTrue(evidence.startswith("superseded-by: abc123"))

    def test_an_in_review_verify_closes_too(self):
        self.assertTrue(dispatch.superseded_evidence({**self.VERIFY, "status": "in_review"}, (self.MARKER, self.AFTER)))

    def test_no_marker_keeps_it(self):
        self.assertIsNone(dispatch.superseded_evidence(self.VERIFY, None))

    def test_a_marker_older_than_the_verify_keeps_it(self):
        self.assertIsNone(dispatch.superseded_evidence(self.VERIFY, (self.MARKER, self.BEFORE)))

    def test_a_malformed_marker_keeps_it(self):
        self.assertIsNone(dispatch.superseded_evidence(self.VERIFY, ("overlap: src/a.rs\n", self.AFTER)))

    def test_a_closed_verify_is_left_alone(self):
        self.assertIsNone(dispatch.superseded_evidence({**self.VERIFY, "status": "done"}, (self.MARKER, self.AFTER)))


class BaseRedMainRepair(unittest.TestCase):
    MAIN = "a" * 40

    def marker(self, task, sha=None, errors=()):
        return dispatch.parse_base_red(task, "\n".join([sha or self.MAIN, f"V-{task}", *errors]))

    def test_parses_sha_escalator_and_errors(self):
        m = self.marker("T-1", errors=("src/a.rs:3 E0252 dup import", ""))
        self.assertEqual((m.sha, m.escalated, m.errors), (self.MAIN, "V-T-1", ("src/a.rs:3 E0252 dup import",)))

    def test_escalator_defaults_to_the_task(self):
        self.assertEqual(dispatch.parse_base_red("T-1", self.MAIN + "\n").escalated, "T-1")

    def test_a_marker_without_a_sha_is_ignored(self):
        self.assertIsNone(dispatch.parse_base_red("T-1", "not a sha\nV-1\n"))

    def test_one_verify_is_not_enough(self):
        self.assertEqual(dispatch.main_repair_due([self.marker("T-1")], self.MAIN), [])

    def test_two_verifies_on_current_main_file_a_repair(self):
        due = dispatch.main_repair_due([self.marker("T-1"), self.marker("T-2")], self.MAIN)
        self.assertEqual({m.task for m in due}, {"T-1", "T-2"})

    def test_markers_on_an_old_main_do_not_count(self):
        old = "b" * 40
        self.assertEqual(dispatch.main_repair_due([self.marker("T-1", old), self.marker("T-2")], self.MAIN), [])

    def test_body_lists_each_error_once_under_compile_errors(self):
        e = "src/a.rs:3 E0252 dup import"
        body = dispatch.main_repair_body(
            [self.marker("T-1", errors=(e,)), self.marker("T-2", errors=(e, "src/b.rs:9 test failed"))],
            self.MAIN, ".paperclip/worktrees/AA-9", "task/AA-9",
        )
        self.assertIn("Main-repair: origin/main " + self.MAIN, body)
        self.assertEqual(body.count(e), 1)
        self.assertIn("## Compile errors\n- " + e, body)
        self.assertTrue(body.startswith("worktree: .paperclip/worktrees/AA-9\nbranch:   task/AA-9"))


class SentinelRouting(unittest.TestCase):
    MAIN = "a" * 40

    def marker(self, task, errors=(), sha=None):
        return dispatch.BaseRed(task, sha or self.MAIN, f"V-{task}", tuple(errors))

    def verdict(self, base, errors):
        return f"CLOUD-VERIFY-V2\nbase: {base}\nresult: FAIL\n--- errors ---\n{errors}\n"

    def route(self, code, base_red=None, verdict="", known=(), landed=False, base="", struck=False):
        return dispatch.route_sentinel(code, base_red, verdict, self.MAIN, list(known), landed, base, struck)[0]

    def test_superseded_and_reaped_settle(self):
        self.assertEqual(self.route("94"), "settle")
        self.assertEqual(self.route("100"), "settle")

    def test_green_wakes_the_architect_to_land(self):
        self.assertEqual(self.route("0"), "wake")

    def test_green_already_landed_settles(self):
        self.assertEqual(self.route("0", landed=True), "settle")

    def test_red_already_recorded_on_this_main_settles(self):
        self.assertEqual(self.route("1", base_red=self.marker("T-1")), "settle")

    def test_red_recorded_on_an_old_main_wakes(self):
        self.assertEqual(self.route("1", base_red=self.marker("T-1", sha="b" * 40)), "wake")

    def test_red_at_main_s_known_break_is_recorded_without_a_model(self):
        known = [self.marker("T-2", ["src/m.rs:285 test-failure x"])]
        v = self.verdict(self.MAIN, "panicked at src/m.rs:285:9\nassertion failed")
        self.assertEqual(self.route("1", verdict=v, known=known), "base-red")

    def test_an_extra_error_of_its_own_wakes(self):
        known = [self.marker("T-2", ["src/m.rs:285 test-failure x"])]
        v = self.verdict(self.MAIN, "src/m.rs:285:9 failed\n--> src/mine.rs:10:4 E0308")
        self.assertEqual(self.route("1", verdict=v, known=known), "wake")

    def test_a_verdict_built_on_another_main_wakes(self):
        known = [self.marker("T-2", ["src/m.rs:285 x"])]
        v = self.verdict("c" * 40, "src/m.rs:285:9 failed")
        self.assertEqual(self.route("1", verdict=v, known=known), "wake")

    def test_a_red_no_other_verify_blamed_wakes(self):
        self.assertEqual(self.route("1", verdict=self.verdict(self.MAIN, "src/m.rs:285:9")), "wake")

    def test_conflict_and_environment_failures_still_wake(self):
        for code in ("98", "137", "95", "96"):
            self.assertEqual(self.route(code), "wake", code)

    def test_a_first_inconclusive_build_is_relaunched_without_a_model(self):
        for code in ("99", "75"):
            self.assertEqual(self.route(code), "retry", code)

    def test_a_second_inconclusive_in_a_row_wakes(self):
        for code in ("99", "75"):
            self.assertEqual(self.route(code, struck=True), "wake", code)

    def test_green_on_a_moved_main_re_verifies_without_a_model(self):
        self.assertEqual(self.route("0", base="b" * 40), "fresh")

    def test_green_on_the_current_main_wakes_to_land(self):
        self.assertEqual(self.route("0", base=self.MAIN), "wake")

    def test_green_already_landed_settles_even_on_a_moved_main(self):
        self.assertEqual(self.route("0", base="b" * 40, landed=True), "settle")

    def test_rebased_onto_wins_over_base(self):
        v = f"base: {'c' * 40}\nrebased-onto: {self.MAIN}\n--- errors ---\nsrc/m.rs:1\n"
        self.assertEqual(dispatch.verdict_base(v), self.MAIN)


class SentinelSweep(unittest.TestCase):
    """route_sentinels: what reaches the Architect when a relaunch is tried."""

    MAIN = "a" * 40

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        self.saved = (dispatch.VERIFY_DIR, dispatch.STATE_DIR, dispatch.git, dispatch.relaunch, dispatch.start_landing,
                      dispatch.local_landable)
        self.local_ok = False
        dispatch.local_landable = lambda parent: self.local_ok
        dispatch.VERIFY_DIR, dispatch.STATE_DIR = root / "verify", root / "state"
        dispatch.VERIFY_DIR.mkdir()
        dispatch.STATE_DIR.mkdir()
        (dispatch.STATE_DIR / "sentinels.json").write_text('{"_seeded": "1"}')
        dispatch.git = lambda project, *args: self.MAIN
        self.relaunched = []
        self.relaunch_ok = True

        def fake_relaunch(api, verify, parent, mode, why, express=False):
            self.relaunched.append((parent, mode))
            return self.relaunch_ok
        dispatch.relaunch = fake_relaunch
        self.landed = []

        def fake_start(api, verify, parent):
            self.landed.append(parent["identifier"])
            return True
        dispatch.start_landing = fake_start

    def tearDown(self):
        (dispatch.VERIFY_DIR, dispatch.STATE_DIR, dispatch.git, dispatch.relaunch, dispatch.start_landing,
         dispatch.local_landable) = self.saved
        self.tmp.cleanup()

    def sentinel(self, code, base=None):
        path = dispatch.VERIFY_DIR / "T-1.exit"
        path.write_text(code + "\n")
        os.utime(path, (time.time() + len(self.relaunched) + 1,) * 2)  # a new mtime per sentinel
        if base:
            (dispatch.VERIFY_DIR / "T-1.base").write_text(base + "\n")

    def sweep(self, parent=None):
        api = SweepApi(parent=parent)
        dispatch.route_sentinels(api, {"Architect": "arch"}, Path(self.tmp.name))
        return [w for w in api.writes if w[0] == "POST" and w[1].endswith("/wakeup")]

    def verdict(self):
        (dispatch.VERIFY_DIR / "T-1.cloud.verdict").write_text("CLOUD-VERIFY-V2\nresult: PASS\n")

    def finished(self, rc, said="land T-1: done", pid=None):
        pid_f, out_f, rc_f = dispatch.landing_files("T-1")
        pid_f.write_text(f"{pid or 1} v1 V-1\n")
        out_f.write_text(said + "\n")
        rc_f.write_text(f"{rc}\n")

    def test_a_green_cloud_verify_starts_a_landing_without_a_model(self):
        self.verdict()
        self.sentinel("0", base=self.MAIN)
        self.assertEqual(self.sweep(), [])
        self.assertEqual(self.landed, ["T-1"])

    def test_a_local_green_with_no_architect_commit_lands_without_a_model(self):
        self.local_ok = True
        self.sentinel("0", base=self.MAIN)
        self.assertEqual(self.sweep(), [])
        self.assertEqual(self.landed, ["T-1"])

    def test_a_local_green_on_an_older_main_with_no_architect_commit_goes_to_land(self):
        self.local_ok = True
        self.sentinel("0", base="b" * 40)
        self.assertEqual(self.sweep(), [])
        self.assertEqual((self.landed, self.relaunched), (["T-1"], []))

    def test_a_green_on_an_older_main_goes_to_land_not_relaunch(self):
        self.verdict()
        self.sentinel("0", base="b" * 40)
        self.assertEqual(self.sweep(), [])
        self.assertEqual((self.landed, self.relaunched), (["T-1"], []))

    def test_a_running_landing_is_left_alone(self):
        self.verdict()
        self.sentinel("0", base=self.MAIN)
        dispatch.landing_files("T-1")[0].write_text("1 v1 V-1\n")
        alive, dispatch.landing_alive = dispatch.landing_alive, lambda pid: True
        try:
            self.assertEqual(self.sweep(), [])
        finally:
            dispatch.landing_alive = alive
        self.assertEqual(self.landed, [])

    def test_a_landing_that_died_without_a_result_starts_again(self):
        self.verdict()
        self.sentinel("0", base=self.MAIN)
        dispatch.landing_files("T-1")[0].write_text("999999999 v1 V-1\n")
        self.assertEqual(self.sweep(), [])
        self.assertEqual(self.landed, ["T-1"])

    def test_a_landing_handed_back_wakes_the_architect(self):
        self.verdict()
        self.sentinel("0", base=self.MAIN)
        self.finished(1, "land T-1: uncommitted changes in the worktree")
        self.assertEqual(len(self.sweep()), 1)
        self.assertEqual(self.landed, [])
        self.assertFalse(dispatch.landing_files("T-1")[2].exists())

    def test_another_verifys_refusal_does_not_wake_this_one(self):
        self.verdict()
        self.sentinel("0", base=self.MAIN)
        self.finished(1)
        dispatch.landing_files("T-1")[0].write_text("1 v0 V-0\n")
        self.assertEqual(self.sweep(), [])
        self.assertEqual(self.landed, ["T-1"])

    def test_a_finished_landing_is_reported_and_cleared(self):
        self.finished(0, "land T-1: PR confirmed: https://example/pr/1")
        api = SweepApi()
        dispatch.collect_landings(api)
        self.assertEqual([(m, p) for m, p, _ in api.writes], [("POST", "/issues/v1/comments")])
        self.assertIn("Landed by the Dispatcher", api.writes[0][2]["body"])
        self.assertFalse(any(f.exists() for f in dispatch.landing_files("T-1")))

    def test_a_refused_landing_is_left_for_the_sweep(self):
        self.finished(1)
        api = SweepApi()
        dispatch.collect_landings(api)
        self.assertEqual(api.writes, [])
        self.assertTrue(dispatch.landing_files("T-1")[2].exists())

    def test_a_local_green_local_landable_refuses_is_not_landed_by_script(self):
        self.sentinel("0", base=self.MAIN)
        self.assertEqual(len(self.sweep()), 1)
        self.assertEqual(self.landed, [])

    def test_a_main_repair_parent_is_not_landed_by_script(self):
        self.verdict()
        self.sentinel("0", base=self.MAIN)
        self.assertEqual(len(self.sweep(parent={"identifier": "T-1", "title": "ci-fix: x", "labels": []})), 1)
        self.assertEqual(self.landed, [])

    def test_a_relaunch_wakes_no_one(self):
        self.sentinel("99")
        self.assertEqual(self.sweep(), [])
        self.assertEqual(self.relaunched, [("T-1", "retry")])

    def test_a_relaunch_handed_back_wakes_the_architect(self):
        self.relaunch_ok = False
        self.sentinel("0", base="b" * 40)
        self.assertEqual(len(self.sweep()), 1)
        self.assertEqual(self.relaunched, [("T-1", "fresh")])

    def test_the_same_inconclusive_code_twice_wakes_the_second_time(self):
        self.sentinel("99")
        self.assertEqual(self.sweep(), [])
        self.sentinel("99")
        self.assertEqual(len(self.sweep()), 1)
        self.assertEqual(len(self.relaunched), 1)

    def test_a_relaunch_past_the_time_budget_waits_for_the_next_sweep(self):
        saved = dispatch.LAUNCH_BUDGET_S
        dispatch.LAUNCH_BUDGET_S = 0
        try:
            self.sentinel("99")
            self.assertEqual(self.sweep(), [])
            self.assertEqual(self.relaunched, [])
        finally:
            dispatch.LAUNCH_BUDGET_S = saved
        self.sweep()
        self.assertEqual(self.relaunched, [("T-1", "retry")])

    def test_a_real_result_between_clears_the_strike(self):
        self.sentinel("99")
        self.sweep()
        self.sentinel("1")
        self.sweep()
        self.sentinel("99")
        self.assertEqual(self.sweep(), [])
        self.assertEqual([m for _, m in self.relaunched], ["retry", "retry"])


class BuildRecords(unittest.TestCase):
    """Each result the sweep routes is recorded on the task whose branch was built."""

    VERIFY = {"id": "v1", "identifier": "V-1", "parentId": "p1"}
    PARENT = {"id": "p1", "identifier": "T-1"}
    BASE = "b" * 40

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.saved = dispatch.VERIFY_DIR
        dispatch.VERIFY_DIR = Path(self.tmp.name)

    def tearDown(self):
        dispatch.VERIFY_DIR = self.saved
        self.tmp.cleanup()

    def report(self, api, state, code="1", mtime=1_800_000_000.0, cloud=False, action="wake", parent=PARENT):
        dispatch.report_build(api, state, self.VERIFY, parent, "T-1", code, mtime, cloud, self.BASE, action, "why")

    def test_a_result_is_recorded_on_the_parent_with_the_stage_named(self):
        (dispatch.VERIFY_DIR / "T-1.head").write_text("c" * 40 + "\n")
        api, state = SweepApi(), {}
        self.report(api, state)
        (task, build), = api.builds
        self.assertEqual(task, "p1")
        self.assertEqual(
            {k: build[k] for k in ("exitCode", "lane", "finishedAt", "stageIssueId", "headSha", "baseSha", "action")},
            {"exitCode": 1, "lane": "local", "finishedAt": "2027-01-15T08:00:00Z", "stageIssueId": "v1",
             "headSha": "c" * 40, "baseSha": self.BASE, "action": "wake"},
        )

    def test_a_cloud_result_reads_the_head_the_cloud_lane_launched(self):
        (dispatch.VERIFY_DIR / "T-1.head").write_text("c" * 40 + "\n")
        (dispatch.VERIFY_DIR / "T-1.cloud.launched-head").write_text("d" * 40 + "\n")
        api = SweepApi()
        self.report(api, {}, cloud=True)
        self.assertEqual((api.builds[0][1]["lane"], api.builds[0][1]["headSha"]), ("cloud", "d" * 40))

    def test_the_same_result_and_decision_is_sent_once(self):
        api, state = SweepApi(), {}
        self.report(api, state)
        self.report(api, state)
        self.assertEqual(len(api.builds), 1)

    def test_a_new_decision_on_the_same_result_is_sent_again(self):
        api, state = SweepApi(), {}
        self.report(api, state, action="retry")
        self.report(api, state, action="wake")
        self.assertEqual([b["action"] for _, b in api.builds], ["retry", "wake"])
        self.assertEqual(api.builds[0][1]["finishedAt"], api.builds[1][1]["finishedAt"])

    def test_a_main_repair_is_recorded_on_itself_with_no_stage(self):
        api = SweepApi()
        self.report(api, {}, parent=None)
        task, build = api.builds[0]
        self.assertEqual(task, "v1")
        self.assertNotIn("stageIssueId", build)

    def test_a_result_file_that_holds_no_code_is_not_recorded(self):
        api = SweepApi()
        self.report(api, {}, code="")
        self.assertFalse(getattr(api, "builds", []))

    def test_a_record_the_server_refuses_is_retried_on_the_next_sweep(self):
        class Refusing(SweepApi):
            def record_build(self, task_id, build, what):
                raise urllib.error.URLError("down")

        state = {}
        with contextlib.redirect_stdout(io.StringIO()):
            self.report(Refusing(), state)
        api = SweepApi()
        self.report(api, state)
        self.assertEqual(len(api.builds), 1)


class SentinelLiveness(unittest.TestCase):
    """route_sentinels: a result is recorded only once something acts on it."""

    MAIN = SentinelSweep.MAIN
    setUp, tearDown, sentinel = SentinelSweep.setUp, SentinelSweep.tearDown, SentinelSweep.sentinel

    VERIFY = {"id": "v1", "identifier": "V-1", "parentId": "p1", "title": "Verify: T-1 x",
              "dedupeKey": "verify", "status": "in_review", "assigneeAgentId": "arch",
              "updatedAt": "2026-01-01T00:00:00Z"}

    def route(self, verify, live=()):
        api = SweepApi(issues=[verify], live=live)
        dispatch.route_sentinels(api, {"Architect": "arch"}, Path(self.tmp.name))
        return api.writes

    def test_a_dead_execution_run_does_not_swallow_the_result(self):
        self.sentinel("1")
        writes = self.route({**self.VERIFY, "executionRunId": "gone"})
        self.assertEqual([w[1] for w in writes], ["/agents/arch/wakeup"])

    def test_a_live_run_on_the_verify_leaves_the_result_unrecorded(self):
        self.sentinel("1")
        self.assertEqual(self.route({**self.VERIFY, "executionRunId": "r1"}, live=[{"id": "r1", "issueId": "v1"}]), [])
        # The run parked it without acting: the next sweep, with no live run, routes it.
        self.assertEqual([w[1] for w in self.route(self.VERIFY)], ["/agents/arch/wakeup"])

    def test_a_result_written_after_a_verify_was_parked_unparks_it(self):
        self.sentinel("1")
        writes = self.route({**self.VERIFY, "status": "blocked"})
        self.assertEqual(writes, [("PATCH", "v1", {"status": "in_review", "assigneeAgentId": None}),
                                  ("PATCH", "/issues/v1", {"assigneeAgentId": "arch"})])

    def test_a_parked_verify_whose_block_comment_is_newer_is_left(self):
        self.sentinel("1")
        later = {**self.VERIFY, "status": "blocked", "updatedAt": "2999-01-01T00:00:00Z"}
        self.assertEqual(self.route(later), [])


class MainRepairSentinel(SentinelSweep):
    """A parentless `ci-fix:` main-repair: its sentinel is keyed by its own identifier."""

    REPAIR = {"id": "r1", "identifier": "R-1", "title": "ci-fix: aaaaaaaaa — main is red (2 verifies escalated on it)",
              "dedupeKey": None, "status": "in_review", "assigneeAgentId": "arch"}

    def sentinel(self, code, base=None):
        (dispatch.VERIFY_DIR / "R-1.exit").write_text(code + "\n")
        if base:
            (dispatch.VERIFY_DIR / "R-1.base").write_text(base + "\n")

    def sweep(self):
        api = SweepApi(issues=[self.REPAIR])
        dispatch.route_sentinels(api, {"Architect": "arch"}, Path(self.tmp.name))
        return [w for w in api.writes if w[0] == "POST" and w[1].endswith("/wakeup")]

    def test_a_green_repair_wakes_the_architect(self):
        self.sentinel("0", base=self.MAIN)
        wakes = self.sweep()
        self.assertEqual([w[2]["payload"]["issueIdentifier"] for w in wakes], ["R-1"])

    def test_a_green_repair_on_an_older_main_wakes_rather_than_rebuilds(self):
        self.sentinel("0", base="b" * 40)
        self.assertEqual(len(self.sweep()), 1)
        self.assertEqual(self.relaunched, [])

    def test_a_red_repair_is_never_parked_as_base_red(self):
        for task in ("T-1", "T-2"):
            (dispatch.VERIFY_DIR / f"{task}.base-red").write_text(f"{self.MAIN}\nV-{task}\nsrc/m.rs:1 E0063\n")
        (dispatch.VERIFY_DIR / "R-1.cloud.verdict").write_text(
            f"CLOUD-VERIFY-V2\nbase: {self.MAIN}\nresult: FAIL\n--- errors ---\nsrc/m.rs:1 E0063\n")
        self.sentinel("1")
        self.assertEqual(len(self.sweep()), 1)
        self.assertFalse((dispatch.VERIFY_DIR / "R-1.base-red").exists())

    def test_a_routed_sentinel_is_not_routed_again(self):
        self.sentinel("0", base=self.MAIN)
        self.sweep()
        self.assertEqual(self.sweep(), [])

    # The inherited relaunch cases are written against T-1's sentinel.
    test_a_relaunch_wakes_no_one = None
    test_a_relaunch_handed_back_wakes_the_architect = None
    test_the_same_inconclusive_code_twice_wakes_the_second_time = None
    test_a_relaunch_past_the_time_budget_waits_for_the_next_sweep = None
    test_a_real_result_between_clears_the_strike = None
    test_a_green_cloud_verify_starts_a_landing_without_a_model = None
    test_a_green_on_an_older_main_goes_to_land_not_relaunch = None
    test_a_running_landing_is_left_alone = None
    test_a_landing_that_died_without_a_result_starts_again = None
    test_a_landing_handed_back_wakes_the_architect = None
    test_another_verifys_refusal_does_not_wake_this_one = None
    test_a_finished_landing_is_reported_and_cleared = None
    test_a_refused_landing_is_left_for_the_sweep = None
    test_a_local_green_local_landable_refuses_is_not_landed_by_script = None
    test_a_local_green_with_no_architect_commit_lands_without_a_model = None
    test_a_local_green_on_an_older_main_with_no_architect_commit_goes_to_land = None
    test_a_main_repair_parent_is_not_landed_by_script = None


class MainRepairDedupe(unittest.TestCase):
    def repair(self, sha, status):
        return {"identifier": f"R-{sha}", "title": f"ci-fix: {sha} — main is red (2 verifies escalated on it)",
                "status": status}

    def test_a_live_repair_for_an_older_sha_blocks_another_filing(self):
        self.assertIsNotNone(dispatch.existing_main_repair([self.repair("bbbbbbbbb", "in_review")], "aaaaaaaaa"))

    def test_a_blocked_repair_only_covers_its_own_sha(self):
        self.assertIsNone(dispatch.existing_main_repair([self.repair("bbbbbbbbb", "blocked")], "aaaaaaaaa"))
        self.assertIsNotNone(dispatch.existing_main_repair([self.repair("aaaaaaaaa", "blocked")], "aaaaaaaaa"))

    def test_a_finished_repair_for_an_older_sha_does_not_block(self):
        self.assertIsNone(dispatch.existing_main_repair([self.repair("bbbbbbbbb", "done")], "aaaaaaaaa"))

    def test_a_cancelled_repair_for_this_sha_does_not_block(self):
        self.assertIsNone(dispatch.existing_main_repair([self.repair("aaaaaaaaa", "cancelled")], "aaaaaaaaa"))

    def test_a_coordinator_ci_fix_is_not_a_main_repair(self):
        other = {"identifier": "C-1", "title": "ci-fix: run 123 failed", "status": "in_review"}
        self.assertIsNone(dispatch.existing_main_repair([other], "aaaaaaaaa"))


class DispatcherLaunch(unittest.TestCase):
    """A Verify the Dispatcher launches stays off the Architect until a model is needed."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        self.saved = (dispatch.VERIFY_DIR, dispatch.STATE_DIR, dispatch.git, dispatch.run_relaunch,
                      dispatch.watcher_alive, dispatch.local_build_alive)
        dispatch.VERIFY_DIR, dispatch.STATE_DIR = root / "verify", root / "state"
        dispatch.VERIFY_DIR.mkdir()
        dispatch.STATE_DIR.mkdir()
        (dispatch.STATE_DIR / "sentinels.json").write_text('{"_seeded": "1"}')
        dispatch.git = lambda project, *args: "a" * 40
        self.rc = 0
        self.said = "relaunch-verify T-1: relaunched in the cloud lane (first launch)"
        self.launches = []

        def fake_run_relaunch(verify, parent, mode, express=False):
            self.launches.append((parent, mode, express))
            return subprocess.CompletedProcess([], self.rc, self.said + "\n", "")
        dispatch.run_relaunch = fake_run_relaunch
        dispatch.watcher_alive = lambda parent: False
        self.local_alive = False
        dispatch.local_build_alive = lambda parent: self.local_alive
        self.agents = {"Architect": "arch", "Dispatcher": "disp"}

    def tearDown(self):
        (dispatch.VERIFY_DIR, dispatch.STATE_DIR, dispatch.git, dispatch.run_relaunch,
         dispatch.watcher_alive, dispatch.local_build_alive) = self.saved
        self.tmp.cleanup()

    def verify(self, owner="disp"):
        return {"id": "v1", "identifier": "V-1", "parentId": "p1", "title": "Verify: T-1 x",
                "dedupeKey": "verify", "status": "in_review", "assigneeAgentId": owner}

    def assignees(self, api):
        return [w[2].get("assigneeAgentId") for w in api.writes if w[0] == "PATCH"]

    def test_a_launch_keeps_the_verify_off_the_architect(self):
        api = SweepApi()
        self.assertTrue(dispatch.launch_verify(api, self.agents, self.verify(), {"identifier": "T-1"}))
        self.assertEqual(self.assignees(api), [])

    def test_a_local_launch_keeps_the_verify_off_the_architect_and_says_where(self):
        self.said = "relaunch-verify T-1: the cloud lane refused the offload; launched locally (first launch)"
        api = SweepApi()
        self.assertTrue(dispatch.launch_verify(api, self.agents, self.verify(), {"identifier": "T-1"}))
        self.assertEqual(self.assignees(api), [])
        comments = [w[2]["body"] for w in api.writes if w[0] == "POST" and w[1].endswith("/comments")]
        self.assertIn("this machine is building it", comments[0])

    def test_a_priority_task_launches_in_the_express_lane(self):
        dispatch.launch_verify(SweepApi(), self.agents, self.verify(),
                               {"identifier": "T-1", "description": "Priority-verify: unblocks three branches"})
        dispatch.launch_verify(SweepApi(), self.agents, self.verify(), {"identifier": "T-1", "description": "x"})
        self.assertEqual([l[2] for l in self.launches], [True, False])

    def test_a_held_verify_with_a_live_local_build_is_left_alone(self):
        self.local_alive = True
        api = SweepApi()
        dispatch.tend_launch(api, self.agents, self.verify(), "T-1")
        self.assertEqual(api.writes, [])

    def test_a_held_verify_launched_moments_ago_is_left_alone(self):
        (dispatch.VERIFY_DIR / "T-1.log").write_text("local-verify: launching T-1 for V-1\n")
        api = SweepApi()
        dispatch.tend_launch(api, self.agents, self.verify(), "T-1")
        self.assertEqual(api.writes, [])

    def test_a_held_verify_whose_local_build_died_goes_to_the_architect(self):
        log = dispatch.VERIFY_DIR / "T-1.log"
        log.write_text("an old build\n")
        os.utime(log, (time.time() - 3600,) * 2)
        api = SweepApi()
        dispatch.tend_launch(api, self.agents, self.verify(), "T-1")
        self.assertEqual(self.assignees(api), ["arch"])

    def test_a_refused_launch_assigns_the_architect(self):
        self.rc = 1
        api = SweepApi()
        self.assertFalse(dispatch.launch_verify(api, self.agents, self.verify(), {"identifier": "T-1"}))
        self.assertEqual(self.assignees(api), ["arch"])

    def test_a_verify_it_does_not_hold_is_left_alone(self):
        api = SweepApi()
        self.assertFalse(dispatch.launch_verify(api, self.agents, self.verify("arch"), {"identifier": "T-1"}))
        self.assertEqual(api.writes, [])

    def test_main_repair_and_review_titles_go_to_the_architect(self):
        self.assertTrue(dispatch.needs_architect({"title": "ci-fix: x", "labels": []}))
        self.assertTrue(dispatch.needs_architect({"title": "x", "labels": [{"name": "ci-failure"}]}))
        self.assertTrue(dispatch.needs_architect({"title": "x", "description": "Main-repair: yes", "labels": []}))
        self.assertTrue(dispatch.needs_architect({"title": "Review and verify x", "labels": []}))
        self.assertIsNone(dispatch.needs_architect({"title": "Add a feat", "labels": []}))

    def sweep(self, owner):
        api = SweepApi(owner)
        dispatch.route_sentinels(api, self.agents, Path(self.tmp.name))
        return api

    def test_a_result_needing_a_model_is_handed_over_by_assignment(self):
        (dispatch.VERIFY_DIR / "T-1.exit").write_text("1\n")
        api = self.sweep("disp")
        self.assertEqual(self.assignees(api), ["arch"])
        self.assertFalse(any(w[1].endswith("/wakeup") for w in api.writes))

    def test_a_base_red_park_moves_it_to_the_architect_while_blocked(self):
        (dispatch.VERIFY_DIR / "T-2.base-red").write_text("a" * 40 + "\nV-2\nsrc/m.rs:1 E0308 x\n")
        (dispatch.VERIFY_DIR / "T-1.exit").write_text("1\n")
        v = "CLOUD-VERIFY-V2\nbase: " + "a" * 40 + "\n--- errors ---\n--> src/m.rs:1:4 E0308\n"
        (dispatch.VERIFY_DIR / "T-1.cloud.verdict").write_text(v)
        api = self.sweep("disp")
        patches = [w[2] for w in api.writes if w[0] == "PATCH"]
        self.assertEqual(patches, [{"status": "blocked", "assigneeAgentId": "arch"}])

    def test_no_result_and_no_launch_on_record_goes_to_the_architect(self):
        self.assertEqual(self.assignees(self.sweep("disp")), ["arch"])

    def test_a_build_still_out_is_left_alone(self):
        (dispatch.VERIFY_DIR / "T-1.cloud.launched").write_text("1\n")
        self.assertEqual(self.sweep("disp").writes, [])

    def test_the_architect_s_own_verify_without_a_result_is_not_touched(self):
        self.assertEqual(self.sweep("arch").writes, [])


class CloudLaneFlag(unittest.TestCase):
    """The Dispatcher offloads under the Architect's switch, not its own env."""

    def tearDown(self):
        os.environ.pop("ARCHITECT_CLOUD_LANE", None)

    def roster(self, env):
        return [{"name": "Architect", "adapterConfig": {"env": env}}, {"name": "Dispatcher", "adapterConfig": {"env": {}}}]

    def test_the_architect_s_flag_is_inherited(self):
        dispatch.inherit_cloud_lane(self.roster({"ARCHITECT_CLOUD_LANE": {"type": "plain", "value": "1"}}))
        self.assertEqual(os.environ.get("ARCHITECT_CLOUD_LANE"), "1")

    def test_the_architect_s_rollback_clears_it(self):
        os.environ["ARCHITECT_CLOUD_LANE"] = "1"
        dispatch.inherit_cloud_lane(self.roster({}))
        self.assertIsNone(os.environ.get("ARCHITECT_CLOUD_LANE"))


class SweepApi:
    dry_run = False

    def __init__(self, owner="arch", issues=None, parent=None, live=()):
        self.writes = []
        self.owner = owner
        self.listed = issues
        self.live = list(live)
        self.parent = parent or {"identifier": "T-1", "title": "Add a feat", "labels": []}

    def issues(self, **query):
        if query.get("assigneeAgentId", self.owner) != self.owner:
            return []
        if self.listed is not None:
            return self.listed
        return [{"id": "v1", "identifier": "V-1", "parentId": "p1", "title": "Verify: T-1 x",
                 "dedupeKey": "verify", "status": "in_review", "assigneeAgentId": self.owner}]

    def get(self, path):
        if path.endswith("/live-runs"):
            return self.live
        if path.endswith("/comments"):
            return []
        return self.parent

    def write(self, method, path, body, what):
        self.writes.append((method, path, body))

    def set_status(self, issue, body, comment, what):
        self.writes.append(("PATCH", issue["id"], body))

    def record_build(self, task_id, build, what):
        self.builds = [*getattr(self, "builds", []), (task_id, build)]


class TrainHeads(unittest.TestCase):
    def test_train_head_is_also_the_tasks_pr(self):
        heads = dispatch.by_head([{"headRefName": "train/7/AA-13055", "headRefOid": "o"}], "headRefOid")
        self.assertEqual(heads["task/AA-13055"], "o")
        self.assertEqual(heads["train/7/AA-13055"], "o")

    def test_real_task_head_wins_over_the_alias(self):
        prs = [{"headRefName": "train/7/AA-1", "number": 2}, {"headRefName": "task/AA-1", "number": 1}]
        self.assertEqual(dispatch.by_head(prs, "number")["task/AA-1"], 1)

    def test_other_heads_get_no_alias(self):
        heads = dispatch.by_head([{"headRefName": "train-src/AA-1", "number": 3},
                                  {"headRefName": "op/train/7/AA-1", "number": 4}], "number")
        self.assertNotIn("task/AA-1", heads)

    def test_train_merged_into_a_stacked_base_is_no_alias(self):
        prs = [{"headRefName": "train/1/AA-2", "number": 5, "state": "MERGED", "baseRefName": "train/1/AA-1"},
               {"headRefName": "train/1/AA-1", "number": 4, "state": "MERGED", "baseRefName": "main"}]
        merged = dispatch.by_head(prs, "number")
        self.assertNotIn("task/AA-2", merged)
        self.assertEqual(merged["task/AA-1"], 4)

    def test_a_train_prd_task_is_skipped_as_pr_open(self):
        heads = dispatch.by_head([{"headRefName": "train/2/T-1", "headRefOid": "o"}], "headRefOid")
        stages = [child("Review: Thing", "done", "t3")]
        self.assertEqual(decide(parent(), stages, CLEAN).kind, "verify")  # without the PR
        self.assertEqual(decide(parent(), stages, CLEAN, heads.get("task/T-1")).reason, "PR open")


class MainHasDir(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        import subprocess, tempfile
        cls.tmp = tempfile.TemporaryDirectory()
        wt = Path(cls.tmp.name)
        run = lambda *a: subprocess.run(["git", "-C", str(wt), *a], check=True, capture_output=True)
        run("init", "-q")
        (wt / "a").mkdir()
        (wt / "a" / "b.rs").write_text("")
        run("add", ".")
        run("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "x")
        run("update-ref", "refs/remotes/origin/main", "HEAD")
        cls.wt = wt

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def test_split_directory_is_found(self):
        self.assertTrue(dispatch.main_has_dir(self.wt, "a"))

    def test_plain_delete_is_not_a_split(self):
        self.assertFalse(dispatch.main_has_dir(self.wt, "gone"))



class VerifyQuietSince(unittest.TestCase):
    """quiet_since for a parent the Architect holds with no `Verify:` stage."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.saved = dispatch.VERIFY_DIR, dispatch.STATE_DIR
        dispatch.VERIFY_DIR = dispatch.STATE_DIR = Path(self.tmp.name)
        self.quiet = dispatch.verify_quiet_since(api=None)

    def tearDown(self):
        dispatch.VERIFY_DIR, dispatch.STATE_DIR = self.saved
        self.tmp.cleanup()

    def issue(self, status="in_review"):
        return {"identifier": "T-1", "title": "Author a thing", "status": status}

    def test_a_parent_with_its_build_running_is_not_quiet(self):
        (dispatch.VERIFY_DIR / "T-1.pid").write_text(str(os.getpid()))
        self.assertIsNone(self.quiet(self.issue()))

    def test_a_parent_sentinel_counts_without_a_routing(self):
        sentinel = dispatch.VERIFY_DIR / "T-1.exit"
        sentinel.write_text("0")
        self.assertEqual(self.quiet(self.issue()), sentinel.stat().st_mtime)

    def test_an_in_progress_parent_has_no_off_board_work(self):
        (dispatch.VERIFY_DIR / "T-1.pid").write_text(str(os.getpid()))
        self.assertEqual(self.quiet(self.issue("in_progress")), 0.0)

if __name__ == "__main__":
    unittest.main()


class StrandedTodoTest(unittest.TestCase):
    NOW = 1_000_000.0

    def todo(self, age, **kw):
        stamp = datetime.fromtimestamp(self.NOW - age, timezone.utc).isoformat()
        return {"identifier": "AA-1", "status": "todo", "title": "§4.1 — do a thing",
                "updatedAt": stamp, **kw}

    def test_an_unassigned_todo_past_the_grace_is_stranded(self):
        self.assertEqual(len(dispatch.stranded_todos([self.todo(3600)], self.NOW, 600)), 1)

    def test_a_toggle_in_flight_is_left_alone(self):
        # Every re-dispatch passes through todo + null for a moment.
        self.assertEqual(dispatch.stranded_todos([self.todo(5)], self.NOW, 600), [])

    def test_an_assigned_todo_is_not_stranded(self):
        issues = [self.todo(3600, assigneeAgentId="w"), self.todo(3600, assigneeUserId="u")]
        self.assertEqual(dispatch.stranded_todos(issues, self.NOW, 600), [])

    def test_a_held_verify_waiting_for_capacity_is_not_stranded(self):
        held = self.todo(3600, title="Verify: AA-2 something", dedupeKey="verify", parentId="p")
        self.assertEqual(dispatch.stranded_todos([held], self.NOW, 600), [])

    def test_other_statuses_are_ignored(self):
        self.assertEqual(dispatch.stranded_todos([self.todo(3600, status="backlog")], self.NOW, 600), [])
