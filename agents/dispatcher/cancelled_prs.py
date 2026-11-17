"""Close the open PR of a task that was cancelled.

A cancelled task has nothing left to land its branch, but cancelling it never touched
its PR. A draft stayed open, conflicting, for hours after its task was re-filed or
dropped, and read on GitHub as work still in flight. The PR list is the operator's
view of what the pipeline is landing, so every dead entry there is noise to read past.

  open PR on `task/<id>`, task `cancelled`  -> close it unmerged, branch kept

Only `cancelled` closes. A `done` task can still have an open PR legitimately (the
landing records `done` from the merge, and a done-acceptance path is its own audit),
and every live status means the task may still land the branch. The branch is kept:
deleting it is §Worktree teardown's call, which records the disposition first.

A closed PR is read downstream as a decision (Coordinator step 8 stops re-dispatching
the task). That is the intent here: the task is already cancelled. A task re-opened
later starts from that same "closed PR" stop, which is the operator's call to undo.
"""

from __future__ import annotations

import re
import subprocess
import urllib.error
from pathlib import Path

TASK_HEAD = re.compile(r"^task/([A-Z][A-Z0-9]*-\d+)$")
#: A sweep that would close more than this many PRs stops at the cap and says so.
#: A misread task status would otherwise close every open PR at once.
MAX_CLOSES = 5


def task_id(pr: dict) -> str | None:
    """The task a PR's head branch belongs to, or None for any other branch."""
    m = TASK_HEAD.match(pr.get("headRefName") or "")
    return m.group(1) if m else None


def due(prs: list[dict], status_of) -> list[tuple[dict, str]]:
    """The open PRs whose task is cancelled, as (pr, task id). `status_of(id)` may return None."""
    out = []
    for pr in prs:
        tid = task_id(pr)
        if tid and status_of(tid) == "cancelled":
            out.append((pr, tid))
    return out


def close_comment(tid: str, tip: str) -> str:
    return (f"Closing unmerged: task {tid} is `cancelled`, so nothing will land this branch. "
            f"The branch is kept (`task/{tid}` at `{tip[:12]}`). Closed by the Dispatcher's "
            "cancelled-PR sweep.")


def sweep(api, project: Path, prs: list[dict]) -> int:
    """Close the PRs of cancelled tasks, at most MAX_CLOSES per sweep. Returns how many closed."""

    def status_of(tid: str) -> str | None:
        try:
            issue = api.get(f"/issues/{tid}")
        except urllib.error.HTTPError as exc:
            if exc.code == 404:  # a `task/` branch no task carries: not ours to judge
                return None
            raise
        return issue.get("status") if issue else None

    found = due(prs, status_of)
    closed = 0
    for pr, tid in found[:MAX_CLOSES]:
        what = f"cancelled-prs  #{pr['number']}: close, task {tid} cancelled"
        print(("DRY " if api.dry_run else "") + what, flush=True)
        if not api.dry_run:
            try:
                subprocess.run(
                    ["gh", "pr", "close", str(pr["number"]), "--comment",
                     close_comment(tid, pr.get("headRefOid") or "")],
                    cwd=project, capture_output=True, text=True, timeout=60, check=True,
                )
            except subprocess.SubprocessError as exc:
                print(f"  close failed ({exc}); next sweep retries", flush=True)
                continue
        closed += 1
    for pr, tid in found[MAX_CLOSES:]:
        print(f"cancelled-prs  #{pr['number']}: due to close (task {tid}), past the "
              f"{MAX_CLOSES}-per-sweep cap", flush=True)
    return closed
