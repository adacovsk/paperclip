"""Decision tests for cancelled_prs.py.  Run: python3 -m unittest agents/dispatcher/cancelled_prs_test.py"""

import importlib.util
import io
import sys
import unittest
import urllib.error
from contextlib import redirect_stdout
from pathlib import Path
from unittest import mock

_spec = importlib.util.spec_from_file_location("cancelled_prs", Path(__file__).with_name("cancelled_prs.py"))
cancelled_prs = importlib.util.module_from_spec(_spec)
sys.modules["cancelled_prs"] = cancelled_prs
_spec.loader.exec_module(cancelled_prs)


def pr(number, head, oid="abcdef0123456789"):
    return {"number": number, "headRefName": head, "headRefOid": oid}


class FakeApi:
    def __init__(self, statuses, dry_run=False):
        self.statuses = statuses
        self.dry_run = dry_run

    def get(self, path):
        tid = path.rsplit("/", 1)[-1]
        if tid not in self.statuses:
            raise urllib.error.HTTPError(path, 404, "not found", None, None)
        return {"identifier": tid, "status": self.statuses[tid]}


class Due(unittest.TestCase):
    def test_only_a_cancelled_task_closes(self):
        statuses = {"AA-1": "cancelled", "AA-2": "done", "AA-3": "in_review", "AA-4": "blocked", "AA-5": "todo"}
        prs = [pr(i, f"task/AA-{i}") for i in range(1, 6)]
        self.assertEqual([(p["number"], t) for p, t in cancelled_prs.due(prs, statuses.get)], [(1, "AA-1")])

    def test_a_branch_that_is_not_a_task_head_is_never_read(self):
        seen = []
        prs = [pr(1, "planner/roadmap"), pr(2, "op/some-fix"), pr(3, "train/4/AA-9"), pr(4, "task/AA-7/extra")]
        self.assertEqual(cancelled_prs.due(prs, lambda t: seen.append(t) or "cancelled"), [])
        self.assertEqual(seen, [])

    def test_an_unknown_task_is_left_open(self):
        self.assertEqual(cancelled_prs.due([pr(1, "task/AA-8")], {}.get), [])


class Sweep(unittest.TestCase):
    def run_sweep(self, statuses, prs, dry_run=False):
        api = FakeApi(statuses, dry_run)
        with mock.patch.object(cancelled_prs.subprocess, "run") as run, redirect_stdout(io.StringIO()) as out:
            closed = cancelled_prs.sweep(api, Path("."), prs)
        return closed, run, out.getvalue()

    def test_closes_with_the_task_and_tip_in_the_comment_and_keeps_the_branch(self):
        closed, run, _ = self.run_sweep({"AA-1": "cancelled"}, [pr(11, "task/AA-1")])
        self.assertEqual(closed, 1)
        argv = run.call_args.args[0]
        self.assertEqual(argv[:4], ["gh", "pr", "close", "11"])
        self.assertNotIn("--delete-branch", argv)
        comment = argv[argv.index("--comment") + 1]
        self.assertIn("AA-1", comment)
        self.assertIn("abcdef012345", comment)

    def test_a_404_task_does_not_end_the_step(self):
        closed, run, _ = self.run_sweep({"AA-2": "cancelled"}, [pr(1, "task/AA-404"), pr(2, "task/AA-2")])
        self.assertEqual(closed, 1)
        self.assertEqual(run.call_args.args[0][3], "2")

    def test_any_other_api_error_propagates(self):
        api = FakeApi({})
        api.get = mock.Mock(side_effect=urllib.error.HTTPError("/issues/AA-1", 500, "boom", None, None))
        with self.assertRaises(urllib.error.HTTPError):
            cancelled_prs.sweep(api, Path("."), [pr(1, "task/AA-1")])

    def test_dry_run_closes_nothing(self):
        closed, run, out = self.run_sweep({"AA-1": "cancelled"}, [pr(1, "task/AA-1")], dry_run=True)
        self.assertEqual(closed, 1)
        run.assert_not_called()
        self.assertIn("DRY cancelled-prs  #1", out)

    def test_the_cap_stops_a_mass_close(self):
        n = cancelled_prs.MAX_CLOSES + 3
        statuses = {f"AA-{i}": "cancelled" for i in range(n)}
        closed, run, out = self.run_sweep(statuses, [pr(i, f"task/AA-{i}") for i in range(n)])
        self.assertEqual(closed, cancelled_prs.MAX_CLOSES)
        self.assertEqual(run.call_count, cancelled_prs.MAX_CLOSES)
        self.assertEqual(out.count("past the"), 3)

    def test_a_failed_close_is_retried_next_sweep_not_counted(self):
        api = FakeApi({"AA-1": "cancelled"})
        failing = mock.Mock(side_effect=cancelled_prs.subprocess.CalledProcessError(1, "gh"))
        with mock.patch.object(cancelled_prs.subprocess, "run", failing), redirect_stdout(io.StringIO()):
            self.assertEqual(cancelled_prs.sweep(api, Path("."), [pr(1, "task/AA-1")]), 0)


if __name__ == "__main__":
    unittest.main()
