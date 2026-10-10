#!/usr/bin/env python3
"""Close every `in_review` parent whose PR merged, then tear its branch down.

This is Coordinator step 8 (§Merge sweep, §Branch disposition on close and
§Worktree teardown) as one command. As prose it was the step fires skipped:
a fire that runs out of patience still runs the one-line script steps, and
drops the long ones, so parents stayed `in_review` for days after merging.

A parent's PR is the merged PR whose head is `task/<id>` or `train/<n>/<id>`
(a train cherry-picks the task's commits onto a stack, so it is that task's PR).

THE GATE. Nothing is closed or deleted unless every commit on the task branch,
local and remote, is on `origin/main`. A commit counts as landed when it is:
  - an ancestor of `origin/main`;
  - in the merged PR's own head, and that PR's merge commit is on `main`;
  - patch-equivalent to a commit on `main` (`git cherry`); or
  - for a train PR, a cherry-pick of it that the train PR's merge brought in:
    same author, author time and subject. A cherry-pick that resolved a
    conflict changes the patch, but keeps all three; or
  - for a train PR, in the snapshot the train was cut from (`train-src/<id>`):
    an ancestor of it, patch-equivalent to it, or the same pick key. A train
    stacks onto other trains and may rework a commit while resolving, so its
    merge range need not hold a pick of every task commit; the snapshot is
    what the merged train PR was built from, which is the same claim.
    A commit made on the task branch after the snapshot was cut is in none
    of these and is refused: the train never saw it.
Whatever the per-commit tests say, a branch whose merge into `origin/main`
produces main's own tree has nothing main lacks, and passes: that is what
covers a `Merge origin/main into task/...` commit, whose content is main's.
A branch that fails is reported with its unlanded commits and left alone:
status, worktree and both branches untouched. An accumulating unmerged branch
is a visible, cheap problem; a deleted one is invisible and permanent.

On a pass: reap any verify build still running for the task, comment the
disposition (Landed, with the PR), PATCH the parent `done`, then remove the
worktree (never forced — a dirty one is kept and reported), the local branch
and the remote `task/<id>` branch.

A closed-unmerged PR is not handled here; it is a decision for the Coordinator.

Usage: merge-sweep.py [--dry-run]
Env:   PAPERCLIP_PROJECT (required), PAPERCLIP_COMPANY_ID (required),
       PAPERCLIP_API_URL (default http://127.0.0.1:3100), PAPERCLIP_API_KEY.
Exit:  0 swept (including nothing to do), 2 origin/main or the PR list unreadable.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.request
from dataclasses import dataclass
from pathlib import Path

# What `git cherry-pick` carries over unchanged, however the patch was resolved.
PICK_KEY = "%ae %at %s"
REAP = Path(__file__).resolve().parent.parent / "architect" / "reap-verify.sh"


@dataclass(frozen=True)
class Pr:
    number: int
    head: str
    head_oid: str
    merge_oid: str

    @property
    def is_train(self) -> bool:
        return self.head.startswith("train/")


def run(project: Path, *args: str, check: bool = False) -> subprocess.CompletedProcess:
    return subprocess.run(args, cwd=project, capture_output=True, text=True, check=check)


def git(project: Path, *args: str) -> str:
    return run(project, "git", *args, check=True).stdout.strip()


def git_ok(project: Path, *args: str) -> bool:
    return run(project, "git", *args).returncode == 0


def merged_prs(project: Path) -> list[dict]:
    out = run(project, "gh", "pr", "list", "--state", "merged", "--limit", "500",
              "--json", "number,headRefName,headRefOid,mergeCommit", check=True).stdout
    return json.loads(out)


def find_pr(prs: list[dict], identifier: str) -> Pr | None:
    """The task's merged PR: `task/<id>` first, else a `train/<n>/<id>` head."""
    train = re.compile(rf"^train/\d+/{re.escape(identifier)}$")
    hits = [p for p in prs if p.get("mergeCommit") and p["headRefName"] == f"task/{identifier}"]
    hits = hits or [p for p in prs if p.get("mergeCommit") and train.match(p["headRefName"])]
    if not hits:
        return None
    p = hits[0]
    return Pr(p["number"], p["headRefName"], p["headRefOid"], p["mergeCommit"]["oid"])


def snapshot_ref(project: Path, pr: Pr) -> str | None:
    """`origin/train-src/<id>` for a train PR, if that branch still exists."""
    if not pr.is_train:
        return None
    ref = "origin/train-src/" + pr.head.rsplit("/", 1)[-1]
    return ref if git_ok(project, "rev-parse", "-q", "--verify", ref) else None


def unlanded(project: Path, ref: str, pr: Pr) -> list[str]:
    """Commits on `ref` that are not on origin/main by any of the gate's five tests."""
    commits = git(project, "rev-list", f"origin/main..{ref}").split()
    if not commits:
        return []
    merged = run(project, "git", "merge-tree", "--write-tree", "origin/main", ref)
    if merged.returncode == 0 and merged.stdout.split()[0] == git(project, "rev-parse", "origin/main^{tree}"):
        return []
    pr_landed = git_ok(project, "merge-base", "--is-ancestor", pr.merge_oid, "origin/main")
    have_head = git_ok(project, "cat-file", "-e", f"{pr.head_oid}^{{commit}}")
    equivalent = {line[2:] for line in git(project, "cherry", "origin/main", ref).splitlines()
                  if line.startswith("- ")}
    picked: set[str] = set()
    if pr.is_train and pr_landed:
        picked = set(git(project, "log", f"--format={PICK_KEY}", f"{pr.merge_oid}^1..{pr.merge_oid}^2").splitlines())
    snap = snapshot_ref(project, pr) if pr_landed else None
    if snap:
        equivalent |= {line[2:] for line in git(project, "cherry", snap, ref).splitlines()
                       if line.startswith("- ")}
        picked |= set(git(project, "log", f"--format={PICK_KEY}", snap, "--not", "origin/main").splitlines())
    bad = []
    for c in commits:
        if c in equivalent:
            continue
        if pr_landed and have_head and git_ok(project, "merge-base", "--is-ancestor", c, pr.head_oid):
            continue
        if snap and git_ok(project, "merge-base", "--is-ancestor", c, snap):
            continue
        if picked and git(project, "log", "-1", f"--format={PICK_KEY}", c) in picked:
            continue
        bad.append(c)
    return bad


class Api:
    def __init__(self) -> None:
        self.base = os.environ.get("PAPERCLIP_API_URL", "http://127.0.0.1:3100").rstrip("/") + "/api"
        self.company = os.environ["PAPERCLIP_COMPANY_ID"]
        self.headers = {"Content-Type": "application/json"}
        # No X-Paperclip-Run-Id: it binds to a run UUID, and a bad one half-applies a write.
        if os.environ.get("PAPERCLIP_API_KEY"):
            self.headers["Authorization"] = f"Bearer {os.environ['PAPERCLIP_API_KEY']}"

    def call(self, method: str, path: str, body: dict | None = None):
        req = urllib.request.Request(self.base + path, method=method, headers=self.headers,
                                     data=None if body is None else json.dumps(body).encode())
        with urllib.request.urlopen(req, timeout=30) as resp:
            raw = resp.read()
            return json.loads(raw) if raw else None

    def in_review_parents(self) -> list[dict]:
        # Not only top-level tasks: a follow-up filed as another task's child has its
        # own `task/<id>` branch and PR, and filtering on parentId left those in_review
        # forever after merging. Stage children (Verify, Review, Rebase) have no PR
        # headed by their own identifier, so `find_pr` skips them.
        d = self.call("GET", f"/companies/{self.company}/issues?status=in_review")
        return d if isinstance(d, list) else d.get("issues", [])

    def close(self, issue: dict, comment: str) -> None:
        # Comment first: a status flipped with no reason is the unrecoverable half.
        self.call("POST", f"/issues/{issue['id']}/comments", {"body": comment})
        self.call("PATCH", f"/issues/{issue['id']}", {"status": "done"})


def sweep(project: Path, parents: list[dict], prs: list[dict], api, reap, dry: bool) -> list[str]:
    lines = []
    for parent in sorted(parents, key=lambda p: p["identifier"]):
        ident = parent["identifier"]
        pr = find_pr(prs, ident)
        if pr is None:
            continue
        branch = f"task/{ident}"
        refs = [r for r in (branch, f"origin/{branch}") if git_ok(project, "rev-parse", "-q", "--verify", r)]
        bad = {c for r in refs for c in unlanded(project, r, pr)}
        if bad:
            listing = "; ".join(git(project, "log", "-1", "--format=%h %s", c) for c in sorted(bad))
            lines.append(f"{ident}: PR #{pr.number} ({pr.head}) merged, but REFUSED — "
                         f"{len(bad)} commit(s) not on origin/main, left in_review: {listing}")
            continue
        if dry:
            lines.append(f"{ident}: would close (PR #{pr.number}, {pr.head}) and tear down {branch}")
            continue

        reaped = reap(ident)
        how = "the train PR's own merge" if pr.is_train else "the PR's merge"
        api.close(parent, f"Merged: PR #{pr.number} (`{pr.head}`).\n\n"
                          f"Disposition: **Landed** — #{pr.number}. Every commit on `{branch}` "
                          f"(local and origin) is on `origin/main` by ancestry, patch, or a cherry-pick in {how}"
                          f"{' or its `train-src` snapshot' if pr.is_train else ''}. "
                          f"Closed by `merge-sweep.py`.")
        done = [f"{ident}: closed (PR #{pr.number}, {pr.head})"]

        wt = project / ".paperclip" / "worktrees" / ident
        if not reaped:
            done.append(f"verify build not reaped — worktree {wt} and {branch} kept")
        else:
            if wt.exists():
                r = run(project, "git", "worktree", "remove", str(wt))
                done.append("worktree removed" if r.returncode == 0
                            else f"worktree KEPT ({r.stderr.strip().splitlines()[-1] if r.stderr.strip() else 'remove failed'})")
            if not wt.exists() and branch in refs and git_ok(project, "branch", "-D", branch):
                done.append("local branch deleted")
            if f"origin/{branch}" in refs:
                ok = git_ok(project, "push", "-q", "origin", "--delete", branch)
                done.append("remote branch deleted" if ok else "remote branch delete FAILED")
        lines.append("; ".join(done))
    return lines


def reap_verify(project: Path):
    def reap(ident: str) -> bool:
        r = run(project, str(REAP), ident, "pr-merged")
        return r.returncode == 0
    return reap


def main(argv: list[str]) -> int:
    dry = "--dry-run" in argv
    project = Path(os.environ["PAPERCLIP_PROJECT"])
    if not git_ok(project, "fetch", "-q", "--prune", "origin"):
        print("merge-sweep: cannot fetch origin", file=sys.stderr)
        return 2
    try:
        prs = merged_prs(project)
    except (subprocess.CalledProcessError, json.JSONDecodeError):
        print("merge-sweep: cannot list merged PRs", file=sys.stderr)
        return 2
    api = Api()
    try:
        parents = api.in_review_parents()
    except (urllib.error.URLError, OSError) as e:
        print(f"merge-sweep: cannot list in_review tasks: {e}", file=sys.stderr)
        return 2
    for line in sweep(project, parents, prs, api, reap_verify(project), dry):
        print(line)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
