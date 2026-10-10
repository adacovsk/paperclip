"""Signal-table tests for dispatch.py.  Run: python3 -m unittest agents/dispatcher/dispatch_test.py"""

import importlib.util
import os
import tempfile
import time
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
        self.assertIsNone(dispatch.split_dir("assets/a.json"))


class Holds(unittest.TestCase):
    def test_a_legacy_hold_releases_only_once_its_blocker_closed(self):
        self.assertEqual(dispatch.held_closed("Held: waiting on AA-12 — files"), ("AA-12", "closed"))
        self.assertIsNone(dispatch.held_closed("Held: waiting on contended edit surface — x"))
        in_review = {"identifier": "AA-12", "status": "in_review"}
        self.assertIsNone(dispatch.hold_resolved(in_review, "closed", True))
        self.assertIn("cancelled", dispatch.hold_resolved({"identifier": "AA-12", "status": "cancelled"}, "closed", False))

    def test_parses_only_the_release_condition_forms(self):
        self.assertEqual(dispatch.held_until("Held: until AA-12 merges — builds on its seam"), ("AA-12", "merge"))
        self.assertEqual(dispatch.held_until("Held: until AA-12 opens its PR — files"), ("AA-12", "pr"))
        self.assertIsNone(dispatch.held_until("Held: waiting on AA-12 — files"))
        self.assertIsNone(dispatch.held_until("Held: operator — design call"))

    def test_a_re_hold_after_our_release_is_final(self):
        comments = [
            {"createdAt": "1", "body": "Held: until AA-9 opens its PR — files"},
            {"createdAt": "2", "body": "Released: AA-9 has an open PR.\n\n> Held: until AA-9 opens its PR"},
            {"createdAt": "3", "body": "Held: until AA-9 opens its PR — still contended"},
        ]
        self.assertTrue(dispatch.overruled(comments, "AA-9"))

    def test_a_release_on_another_blocker_does_not_count(self):
        comments = [
            {"createdAt": "1", "body": "Released: AA-8 is done.\n\n> Held: until AA-8 merges"},
            {"createdAt": "2", "body": "Held: until AA-9 opens its PR — files"},
        ]
        self.assertFalse(dispatch.overruled(comments, "AA-9"))

    def test_a_first_hold_is_not_overruled(self):
        self.assertFalse(dispatch.overruled([{"createdAt": "1", "body": "Held: until AA-9 merges"}], "AA-9"))

    def test_merge_hold_waits_for_the_merge(self):
        in_review = {"identifier": "A-1", "status": "in_review"}
        self.assertIsNone(dispatch.hold_resolved(in_review, "merge", True))
        self.assertIn("done", dispatch.hold_resolved({"identifier": "A-1", "status": "done"}, "merge", False))

    def test_pr_hold_releases_on_the_pr(self):
        in_review = {"identifier": "A-1", "status": "in_review"}
        self.assertIn("PR", dispatch.hold_resolved(in_review, "pr", True))
        self.assertIsNone(dispatch.hold_resolved(in_review, "pr", False))
        self.assertIsNone(dispatch.hold_resolved(None, "pr", True))



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
        self.saved = (dispatch.VERIFY_DIR, dispatch.STATE_DIR, dispatch.git, dispatch.relaunch)
        dispatch.VERIFY_DIR, dispatch.STATE_DIR = root / "verify", root / "state"
        dispatch.VERIFY_DIR.mkdir()
        dispatch.STATE_DIR.mkdir()
        (dispatch.STATE_DIR / "sentinels.json").write_text('{"_seeded": "1"}')
        dispatch.git = lambda project, *args: self.MAIN
        self.relaunched = []
        self.relaunch_ok = True

        def fake_relaunch(api, verify, parent, mode, why):
            self.relaunched.append((parent, mode))
            return self.relaunch_ok
        dispatch.relaunch = fake_relaunch

    def tearDown(self):
        dispatch.VERIFY_DIR, dispatch.STATE_DIR, dispatch.git, dispatch.relaunch = self.saved
        self.tmp.cleanup()

    def sentinel(self, code, base=None):
        path = dispatch.VERIFY_DIR / "T-1.exit"
        path.write_text(code + "\n")
        os.utime(path, (time.time() + len(self.relaunched) + 1,) * 2)  # a new mtime per sentinel
        if base:
            (dispatch.VERIFY_DIR / "T-1.base").write_text(base + "\n")

    def sweep(self):
        api = SweepApi()
        dispatch.route_sentinels(api, {"Architect": "arch"}, Path(self.tmp.name))
        return [w for w in api.writes if w[0] == "POST" and w[1].endswith("/wakeup")]

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

    def test_a_real_result_between_clears_the_strike(self):
        self.sentinel("99")
        self.sweep()
        self.sentinel("1")
        self.sweep()
        self.sentinel("99")
        self.assertEqual(self.sweep(), [])
        self.assertEqual([m for _, m in self.relaunched], ["retry", "retry"])


class SweepApi:
    dry_run = False

    def __init__(self):
        self.writes = []

    def issues(self, **query):
        return [{"id": "v1", "identifier": "V-1", "parentId": "p1", "title": "Verify: T-1 x",
                 "dedupeKey": "verify", "status": "in_review", "assigneeAgentId": "arch"}]

    def get(self, path):
        return {"identifier": "T-1"}

    def write(self, method, path, body, what):
        self.writes.append((method, path, body))

    def set_status(self, issue, body, comment, what):
        self.writes.append(("PATCH", issue["id"], body))


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


if __name__ == "__main__":
    unittest.main()
