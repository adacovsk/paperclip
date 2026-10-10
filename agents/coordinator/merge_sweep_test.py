"""Tests for merge-sweep.py.  Run: python3 -m unittest agents/coordinator/merge_sweep_test.py

The load-bearing properties: a merged PR closes its parent only when every
commit on the task branch, local and remote, is on main (including a train's
conflict-resolved cherry-picks); a branch carrying anything else is refused and
left exactly as it was; the comment lands before the status; and --dry-run
writes nothing.
"""

import importlib.util
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

_spec = importlib.util.spec_from_file_location("merge_sweep", Path(__file__).with_name("merge-sweep.py"))
ms = importlib.util.module_from_spec(_spec)
sys.modules["merge_sweep"] = ms
_spec.loader.exec_module(ms)

ENV = {**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t",
       "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t"}


class FakeApi:
    def __init__(self):
        self.calls = []

    def close(self, issue, comment):
        self.calls.append(("comment", issue["identifier"], comment))
        self.calls.append(("done", issue["identifier"]))


class Repo:
    def __init__(self, root: Path):
        self.remote = root / "remote.git"
        self.p = root / "proj"
        subprocess.run(["git", "init", "-q", "--bare", "-b", "main", str(self.remote)], check=True)
        subprocess.run(["git", "clone", "-q", str(self.remote), str(self.p)], check=True, env=ENV,
                       capture_output=True)
        self.commit("base.txt", "base", "base")
        self.g("push", "-q", "origin", "main")
        self.n = 0

    def g(self, *args, env=None):
        return subprocess.run(["git", *args], cwd=self.p, check=True, capture_output=True, text=True,
                              env=env or ENV).stdout.strip()

    def commit(self, path, text, msg, date=None):
        (self.p / path).write_text(text + "\n")
        self.g("add", path)
        env = {**ENV, "GIT_AUTHOR_DATE": date} if date else None
        self.g("commit", "-qm", msg, env=env)
        return self.g("rev-parse", "HEAD")

    def task(self, ident, files):
        """task/<ident> off main with one commit per (path, text), pushed; back on main."""
        self.g("checkout", "-qb", f"task/{ident}", "origin/main")
        for i, (path, text) in enumerate(files):
            self.commit(path, text, f"{ident}: {path}", date=f"2026-01-0{i + 1}T00:00:00Z")
        self.g("push", "-q", "origin", f"task/{ident}")
        self.g("checkout", "-q", "main")

    def merge_pr(self, head, delete=True):
        """Merge-commit `head` into main as GitHub does; returns the merged-PR record."""
        self.n += 1
        oid = self.g("rev-parse", head)
        self.g("checkout", "-q", "main")
        self.g("pull", "-q", "--ff-only", "origin", "main")
        self.g("merge", "-q", "--no-ff", "-m", f"Merge pull request #{self.n}", oid)
        self.g("push", "-q", "origin", "main")
        if delete and head.startswith("origin/"):
            self.g("push", "-q", "origin", "--delete", head[len("origin/"):])
        self.g("fetch", "-q", "--prune", "origin")
        return {"number": self.n, "headRefName": head.removeprefix("origin/"), "headRefOid": oid,
                "mergeCommit": {"oid": self.g("rev-parse", "main")}}

    def train(self, n, ident, resolve=None):
        """train/<n>/<ident>: the task's commits cherry-picked onto main; `resolve`
        rewrites one file mid-pick, as a conflict resolution would."""
        self.g("checkout", "-qb", f"train/{n}/{ident}", "origin/main")
        for c in self.g("rev-list", "--reverse", f"origin/main..origin/task/{ident}").split():
            self.g("cherry-pick", "-n", c)
            if resolve:
                path, text = resolve
                if (self.p / path).exists():
                    (self.p / path).write_text(text + "\n")
                    self.g("add", path)
            self.g("commit", "-q", "-C", c)
        self.g("push", "-q", "origin", f"train/{n}/{ident}")
        self.g("checkout", "-q", "main")
        self.g("fetch", "-q", "origin")


def parent(ident):
    return {"id": f"id-{ident}", "identifier": ident, "status": "in_review"}


class MergeSweep(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.r = Repo(Path(self.tmp.name))
        self.api = FakeApi()
        self.reaped = []

    def tearDown(self):
        self.tmp.cleanup()

    def sweep(self, idents, prs, dry=False, reap_ok=True):
        def reap(i):
            self.reaped.append(i)
            return reap_ok
        return ms.sweep(self.r.p, [parent(i) for i in idents], prs, self.api, reap, dry)

    def has_ref(self, ref):
        return subprocess.run(["git", "rev-parse", "-q", "--verify", ref], cwd=self.r.p,
                              capture_output=True).returncode == 0

    def test_task_pr_merged_closes_and_tears_down(self):
        self.r.task("T-1", [("a.txt", "a")])
        wt = self.r.p / ".paperclip" / "worktrees" / "T-1"
        self.r.g("worktree", "add", "-q", str(wt), "task/T-1")
        pr = self.r.merge_pr("origin/task/T-1")
        out = self.sweep(["T-1"], [pr])
        self.assertEqual([c[0] for c in self.api.calls], ["comment", "done"])  # comment first
        self.assertIn("Landed", self.api.calls[0][2])
        self.assertIn("closed (PR #1", out[0])
        self.assertFalse(wt.exists())
        self.assertFalse(self.has_ref("task/T-1"))
        self.assertEqual(self.reaped, ["T-1"])

    def test_train_with_a_conflict_resolved_pick_closes(self):
        self.r.task("T-2", [("b.txt", "b"), ("c.txt", "c")])
        self.r.train(7, "T-2", resolve=("c.txt", "c, resolved"))
        pr = self.r.merge_pr("origin/train/7/T-2")
        self.assertIn("+", self.r.g("cherry", "origin/main", "task/T-2"))  # the patch did change
        out = self.sweep(["T-2"], [pr])
        self.assertEqual(self.api.calls[-1], ("done", "T-2"))
        self.assertIn("train/7/T-2", out[0])
        self.assertIn("remote branch deleted", out[0])
        self.assertFalse(self.has_ref("origin/task/T-2"))

    def test_task_commit_missing_from_the_train_is_refused(self):
        self.r.task("T-3", [("d.txt", "d")])
        self.r.train(2, "T-3")
        pr = self.r.merge_pr("origin/train/2/T-3")
        self.r.g("checkout", "-q", "task/T-3")
        self.r.commit("e.txt", "e", "T-3: e.txt")  # after the train was cut
        self.r.g("checkout", "-q", "main")
        out = self.sweep(["T-3"], [pr])
        self.assertIn("REFUSED", out[0])
        self.assertIn("T-3: e.txt", out[0])
        self.assertEqual(self.api.calls, [])
        self.assertTrue(self.has_ref("task/T-3") and self.has_ref("origin/task/T-3"))
        self.assertEqual(self.reaped, [])

    def test_same_subject_but_not_a_pick_is_refused(self):
        self.r.task("T-4", [("f.txt", "f")])
        self.r.train(3, "T-4")
        pr = self.r.merge_pr("origin/train/3/T-4")
        self.r.g("checkout", "-q", "task/T-4")
        self.r.commit("g.txt", "g", "T-4: f.txt")  # the train's subject, a new commit
        self.r.g("checkout", "-q", "main")
        self.assertIn("REFUSED", self.sweep(["T-4"], [pr])[0])

    def test_commit_after_a_task_pr_merged_is_refused(self):
        self.r.task("T-5", [("h.txt", "h")])
        pr = self.r.merge_pr("origin/task/T-5", delete=False)
        self.r.g("checkout", "-q", "task/T-5")
        self.r.commit("i.txt", "i", "T-5: late")
        self.r.g("push", "-q", "origin", "task/T-5")
        self.r.g("checkout", "-q", "main")
        out = self.sweep(["T-5"], [pr])
        self.assertIn("REFUSED", out[0])
        self.assertIn("T-5: late", out[0])
        self.assertEqual(self.api.calls, [])

    def test_no_merged_pr_is_silent(self):
        self.r.task("T-6", [("j.txt", "j")])
        self.assertEqual(self.sweep(["T-6"], []), [])
        self.assertEqual(self.api.calls, [])

    def test_dry_run_writes_nothing(self):
        self.r.task("T-7", [("k.txt", "k")])
        pr = self.r.merge_pr("origin/task/T-7", delete=False)
        out = self.sweep(["T-7"], [pr], dry=True)
        self.assertIn("would close", out[0])
        self.assertEqual(self.api.calls, [])
        self.assertEqual(self.reaped, [])
        self.assertTrue(self.has_ref("task/T-7") and self.has_ref("origin/task/T-7"))

    def test_dirty_worktree_is_kept(self):
        self.r.task("T-8", [("l.txt", "l")])
        wt = self.r.p / ".paperclip" / "worktrees" / "T-8"
        self.r.g("worktree", "add", "-q", str(wt), "task/T-8")
        (wt / "stray.txt").write_text("uncommitted\n")
        pr = self.r.merge_pr("origin/task/T-8")
        out = self.sweep(["T-8"], [pr])
        self.assertEqual(self.api.calls[-1], ("done", "T-8"))
        self.assertIn("worktree KEPT", out[0])
        self.assertTrue((wt / "stray.txt").exists())
        self.assertTrue(self.has_ref("task/T-8"))  # still checked out there

    def test_unreaped_build_keeps_the_worktree(self):
        self.r.task("T-9", [("m.txt", "m")])
        wt = self.r.p / ".paperclip" / "worktrees" / "T-9"
        self.r.g("worktree", "add", "-q", str(wt), "task/T-9")
        pr = self.r.merge_pr("origin/task/T-9")
        out = self.sweep(["T-9"], [pr], reap_ok=False)
        self.assertIn("not reaped", out[0])
        self.assertTrue(wt.exists())

    def test_task_head_wins_over_a_train_head(self):
        prs = [{"number": 2, "headRefName": "train/1/T-1", "headRefOid": "b", "mergeCommit": {"oid": "y"}},
               {"number": 1, "headRefName": "task/T-1", "headRefOid": "a", "mergeCommit": {"oid": "x"}}]
        self.assertEqual(ms.find_pr(prs, "T-1").number, 1)
        self.assertIsNone(ms.find_pr(prs, "T-10"))  # no prefix match


if __name__ == "__main__":
    unittest.main()
