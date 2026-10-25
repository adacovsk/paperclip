"""Decision tests for reap.py.  Run: python3 -m unittest agents/facilitator/reap_test.py"""

import importlib.util
import sys
import unittest
from pathlib import Path

_spec = importlib.util.spec_from_file_location("reap", Path(__file__).with_name("reap.py"))
reap = importlib.util.module_from_spec(_spec)
sys.modules["reap"] = reap  # its dataclasses resolve their module by name
_spec.loader.exec_module(reap)

NOW = reap.iso("2026-01-31T00:00:00Z")
REPO = Path("/repo")


def task(status, finished="2026-01-30T00:00:00Z"):
    key = "cancelledAt" if status == "cancelled" else "completedAt"
    return {"status": status, key: finished if status in reap.FINISHED else None}


def local(branch, wt=None, dirty=False, on_main=False, on_origin=False, tip="t1"):
    return reap.Local(branch, tip, Path(wt) if wt else None, dirty, on_main, on_origin)


def kinds(acts):
    return [(a.kind, a.target.split("\t")[0]) for a in acts]


class TaskLocals(unittest.TestCase):
    def plan(self, b, status, prs=None, finished="2026-01-30T00:00:00Z"):
        return reap.plan_task_locals(REPO, [b], {"AA-1": task(status, finished)}, prs or {}, NOW)

    def test_a_live_task_is_never_touched(self):
        for status in ("backlog", "todo", "in_progress", "in_review", "blocked"):
            self.assertEqual(self.plan(local("task/AA-1", "/wt"), status), ([], []))

    def test_an_unknown_task_is_never_touched(self):
        acts, kept = reap.plan_task_locals(REPO, [local("task/AA-9", "/wt")], {}, {}, NOW)
        self.assertEqual((acts, kept), ([], []))

    def test_merged_work_removes_the_worktree_and_branch(self):
        acts, _ = self.plan(local("task/AA-1", "/wt", on_main=True), "done")
        self.assertEqual(kinds(acts), [("remove-worktree", "/wt"), ("delete-local", "task/AA-1")])

    def test_work_found_nowhere_else_is_pushed_first(self):
        acts, _ = self.plan(local("task/AA-1", "/wt"), "cancelled")
        self.assertEqual(kinds(acts)[0], ("push", "task/AA-1"))

    def test_work_already_on_origin_is_not_pushed(self):
        acts, _ = self.plan(local("task/AA-1", on_origin=True), "cancelled")
        self.assertEqual(kinds(acts), [("delete-local", "task/AA-1")])

    def test_work_past_the_archive_window_is_not_pushed(self):
        acts, _ = self.plan(local("task/AA-1"), "cancelled", finished="2026-01-01T00:00:00Z")
        self.assertEqual(kinds(acts), [("delete-local", "task/AA-1")])

    def test_a_dirty_worktree_is_kept_and_reported(self):
        acts, kept = self.plan(local("task/AA-1", "/wt", dirty=True, on_main=True), "done")
        self.assertEqual(acts, [])
        self.assertIn("uncommitted", kept[0])

    def test_an_open_pr_is_kept(self):
        acts, kept = self.plan(local("task/AA-1", on_main=True), "done", {"task/AA-1": [{"state": "OPEN"}]})
        self.assertEqual(acts, [])
        self.assertIn("PR still open", kept[0])

    def test_cloud_verify_attempts_are_dropped_unpushed(self):
        acts, _ = self.plan(local("cloud-verify/AA-1/abc"), "done")
        self.assertEqual(kinds(acts), [("delete-local", "cloud-verify/AA-1/abc")])


class TaskRemotes(unittest.TestCase):
    def plan(self, branch, status, finished, prs=None):
        return kinds(reap.plan_task_remotes(REPO, [(branch, "t1")], {"AA-1": task(status, finished)}, prs or {}, NOW))

    def test_cloud_verify_goes_as_soon_as_the_task_finishes(self):
        self.assertEqual(self.plan("cloud-verify/AA-1/abc", "done", "2026-01-30T23:00:00Z"),
                         [("delete-remote", "cloud-verify/AA-1/abc")])

    def test_a_task_branch_waits_out_the_grace(self):
        self.assertEqual(self.plan("task/AA-1", "cancelled", "2026-01-30T00:00:00Z"), [])
        self.assertEqual(self.plan("task/AA-1", "cancelled", "2026-01-20T00:00:00Z"),
                         [("delete-remote", "task/AA-1")])

    def test_a_live_task_or_open_pr_keeps_its_remote(self):
        self.assertEqual(self.plan("task/AA-1", "in_review", None), [])
        self.assertEqual(self.plan("task/AA-1", "done", "2026-01-01T00:00:00Z", {"task/AA-1": [{"state": "OPEN"}]}), [])


class OperatorBranches(unittest.TestCase):
    def plan(self, b, prs):
        return reap.plan_op(REPO, [b], prs)

    def test_merged_and_clean_is_removed_everywhere(self):
        acts, _ = self.plan(local("op/x", "/wt/x", on_main=True, on_origin=True),
                            {"op/x": [{"state": "MERGED", "headRefOid": "t1"}]})
        self.assertEqual(kinds(acts), [("remove-worktree", "/wt/x"), ("delete-local", "op/x"), ("delete-remote", "op/x")])

    def test_unmerged_is_left_alone(self):
        self.assertEqual(self.plan(local("op/x", "/wt/x", on_main=True), {}), ([], []))
        self.assertEqual(self.plan(local("op/x", on_main=True), {"op/x": [{"state": "CLOSED", "headRefOid": "t1"}]}), ([], []))

    def test_commits_after_the_merged_head_are_kept(self):
        acts, kept = self.plan(local("op/x", tip="t2"), {"op/x": [{"state": "MERGED", "headRefOid": "t1"}]})
        self.assertEqual(acts, [])
        self.assertIn("after the merged head", kept[0])

    def test_dirty_is_kept(self):
        acts, kept = self.plan(local("op/x", "/wt/x", dirty=True, on_main=True),
                               {"op/x": [{"state": "MERGED", "headRefOid": "t1"}]})
        self.assertEqual(acts, [])
        self.assertIn("uncommitted", kept[0])


class Sessions(unittest.TestCase):
    def session(self, bucket, revision):
        return {"id": "s1", "status_bucket": bucket, "session_context": {"sources": [{"revision": revision}]}}

    def test_completed_session_of_a_finished_task_is_deleted(self):
        acts = reap.plan_sessions([self.session("completed", "task/AA-1")], {"AA-1": task("done")})
        self.assertEqual(kinds(acts), [("delete-session", "s1")])

    def test_running_live_or_unowned_sessions_are_kept(self):
        tasks = {"AA-1": task("done"), "AA-2": task("in_review")}
        for s in (self.session("working", "task/AA-1"), self.session("completed", "task/AA-2"),
                  self.session("completed", "main"), self.session("completed", "op/x")):
            self.assertEqual(reap.plan_sessions([s], tasks), [])


class CacheAndWatchers(unittest.TestCase):
    def test_cache_files_wait_out_the_grace(self):
        tasks = {"AA-1": task("done", "2026-01-20T00:00:00Z"), "AA-2": task("done"), "AA-3": task("in_review")}
        acts = reap.plan_cache(["AA-1.exit", "AA-1.cloud.log", "AA-2.exit", "AA-3.exit", "train-gate"], tasks, NOW)
        self.assertEqual([a.target for a in acts], ["AA-1.exit", "AA-1.cloud.log"])

    def test_a_finished_tasks_watcher_is_stopped(self):
        tasks = {"AA-1": task("done", "2026-01-20T00:00:00Z"), "AA-2": task("in_review")}
        acts = reap.plan_watchers(["cloudwatch-AA-1-17.scope", "cloudwatch-AA-2-18.scope"], tasks, NOW)
        self.assertEqual([a.target for a in acts], ["cloudwatch-AA-1-17.scope"])


class Ordering(unittest.TestCase):
    def test_a_cap_never_splits_a_push_from_its_delete(self):
        acts = [reap.Action("push", "task/AA-1", "", REPO, "AA-1"),
                reap.Action("delete-local", "task/AA-1", "", REPO, "AA-1"),
                reap.Action("delete-local", "task/AA-2", "", REPO, "AA-2")]
        groups = reap.ordered(acts)
        self.assertEqual([[a.kind for a in g] for g in groups], [["push", "delete-local"], ["delete-local"]])


if __name__ == "__main__":
    unittest.main()
