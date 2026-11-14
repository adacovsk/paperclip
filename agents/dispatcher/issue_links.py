"""Close a GitHub issue once its work is finished, and surface issues nothing is working on.

An issue's number used to travel as text: a marker on the roadmap bullet, a line the
filer copied into the task body, a keyword the lander copied into the PR. Every hop was
a hand-written copy, and each one was skipped somewhere. A design issue sliced into six
roadmap bullets lost its number at the first hop: all six slices landed, and the issue
stayed open for weeks with nothing pointing at it. A scan found eleven of twelve open
roadmapped issues named by no roadmap line and no task.

Tasks now carry the link as a field (`githubIssues` on create, inherited by every stage),
and this sweep owns what the PR keyword did:

  linked tasks all finished, at least one done,
    and no roadmap line names the issue          -> close it, listing the tasks and PRs
  roadmapped, no live or finished linked task,
    and no roadmap line names it                 -> one Planner task to re-attach or close it

A roadmap mention counts as cover because a sliced issue is filed in waves: after the
first slices land, the rest still sit unfiled on the roadmap, and closing then would be
the early close a `Closes` keyword on a partial slice used to cause. The Planner's task is
linked to every issue it names, so the next sweep sees those issues covered and files
nothing twice.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
from dataclasses import dataclass, field
from pathlib import Path

ACTIVE = {"backlog", "todo", "in_progress", "in_review", "blocked"}
#: Labels that mark an issue as accepted roadmap work, so one nothing covers is an orphan.
ROADMAPPED = "roadmapped"
#: Where the target project's roadmap lives, relative to its root.
ROADMAP_PATHS = tuple(os.environ.get("DISPATCHER_ROADMAP_PATHS", "docs/ROADMAP.md docs/roadmap").split())
#: A sweep that would close more than this many issues stops at the cap and says so.
#: A misread roadmap reads as "mentions nothing", which would otherwise close every
#: linked issue at once.
MAX_CLOSES = int(os.environ.get("DISPATCHER_MAX_ISSUE_CLOSES", 5))
ORPHAN_TITLE = "Re-attach GitHub issues no roadmap line or task carries"
_MENTION = re.compile(r"#(\d+)\b")


@dataclass
class Verdict:
    close: list[tuple[dict, list[dict]]] = field(default_factory=list)
    orphans: list[dict] = field(default_factory=list)


def mentions(text: str) -> set[int]:
    """Every `#<n>` in the roadmap text."""
    return {int(n) for n in _MENTION.findall(text)}


def classify(open_issues: list[dict], links: list[dict], mentioned: set[int]) -> Verdict:
    """Which open issues to close and which nothing covers.

    `links` is the server's reverse lookup: one row per (task, issue) with the task's status.
    """
    by_number: dict[int, list[dict]] = {}
    for link in links:
        by_number.setdefault(link["number"], []).append(link)
    verdict = Verdict()
    for issue in sorted(open_issues, key=lambda i: i["number"]):
        tasks = by_number.get(issue["number"], [])
        if issue["number"] in mentioned or any(t["status"] in ACTIVE for t in tasks):
            continue
        if any(t["status"] == "done" for t in tasks):
            verdict.close.append((issue, tasks))
        elif ROADMAPPED in {lbl["name"] for lbl in issue.get("labels", [])}:
            verdict.orphans.append(issue)
    return verdict


def task_pr(identifier: str | None, prs: dict[str, int]) -> int | None:
    return prs.get(f"task/{identifier}") if identifier else None


def close_comment(tasks: list[dict], prs: dict[str, int]) -> str:
    """The landing record: each top-level task, its status, and its PR."""
    lines = []
    for t in tasks:
        if t.get("parentId"):
            continue  # a Review or Verify stage: its parent's line covers it
        pr = task_pr(t.get("identifier"), prs)
        lines.append(f"- {t.get('identifier') or t['issueId']} ({t['status']}): {t['title']}"
                     + (f" — #{pr}" if pr else ""))
    return ("Closed by the pipeline: every task linked to this issue is finished, and no roadmap "
            "line names it any more.\n\n" + "\n".join(lines or ["- (stages only)"]) +
            "\n\nReopen it if work is still owed; a task linked to it keeps it open.")


def orphan_body(orphans: list[dict]) -> str:
    rows = "\n".join(f"- #{i['number']}: {i['title']}" for i in orphans)
    return (
        "What: these open issues are labelled roadmapped, but no roadmap line names them and no "
        "live or finished task is linked to them, so nothing will ever close them.\n\n"
        f"{rows}\n\n"
        "Why: the issue number was dropped on its way from the issue to the work, usually when a "
        "section was sliced or rewritten without carrying its marker.\n\n"
        "Where: the roadmap, and the tasks the work was filed as.\n\n"
        "Done-when: each issue is either named again by the roadmap line(s) that carry its work, "
        "linked to the tasks that did it (POST /api/issues/{id}/github-links), or closed with the "
        "reason. This task is linked to every issue above; finishing it with an issue still "
        "uncovered closes that issue."
    )


# --------------------------------------------------------------------------- I/O


def _run(cmd: list[str], project: Path) -> str:
    return subprocess.run(cmd, cwd=project, capture_output=True, text=True, timeout=60, check=True).stdout


def repo_name(project: Path) -> str:
    return _run(["gh", "repo", "view", "--json", "nameWithOwner", "-q", ".nameWithOwner"], project).strip()


def roadmap_mentions(project: Path) -> set[int]:
    """Issue numbers the roadmap on origin/main names. Raises if the roadmap cannot be read."""
    out = subprocess.run(["git", "grep", "-h", "-o", "-E", r"#[0-9]+", "origin/main", "--", *ROADMAP_PATHS],
                         cwd=project, capture_output=True, text=True, timeout=60)
    if out.returncode not in (0, 1):  # 1 is "no match"; anything else is a failed read
        raise subprocess.CalledProcessError(out.returncode, "git grep", out.stdout, out.stderr)
    found = mentions(out.stdout)
    if not found:
        raise RuntimeError(f"no issue number in {' '.join(ROADMAP_PATHS)} on origin/main; refusing to read that as none")
    return found


def open_issues(project: Path) -> list[dict]:
    return json.loads(_run(["gh", "issue", "list", "--state", "open", "--limit", "500",
                            "--json", "number,title,labels"], project))


def pr_numbers(project: Path) -> dict[str, int]:
    """{`task/<id>`: PR number} for recent PRs, a train head keyed as its task too."""
    prs = json.loads(_run(["gh", "pr", "list", "--state", "all", "--limit", "500",
                           "--json", "headRefName,number"], project))
    out: dict[str, int] = {}
    for pr in prs:
        head = pr["headRefName"]
        out.setdefault(head, pr["number"])
        if head.startswith("train/"):
            out.setdefault("task/" + head.rsplit("/", 1)[-1], pr["number"])
    return out


def sweep(api, project: Path, planner_id: str | None) -> tuple[int, int]:
    """Close finished issues and file one task for uncovered ones. Returns (closed, orphans)."""
    try:
        repo = repo_name(project)
        mentioned = roadmap_mentions(project)
        issues = open_issues(project)
    except (subprocess.SubprocessError, RuntimeError, OSError) as exc:
        print(f"issue-links: skipped, could not read GitHub or the roadmap ({exc})", flush=True)
        return 0, 0
    links = api.get(f"/github-links?repo={repo}")
    verdict = classify(issues, links, mentioned)

    closed = 0
    if verdict.close:
        try:
            prs = pr_numbers(project)
        except (subprocess.SubprocessError, OSError) as exc:
            print(f"issue-links: PR list unreadable ({exc}); closing without PR numbers", flush=True)
            prs = {}
        for issue, tasks in verdict.close[:MAX_CLOSES]:
            what = f"issue-links  #{issue['number']}: close, linked tasks finished"
            print(("DRY " if api.dry_run else "") + what, flush=True)
            if not api.dry_run:
                try:
                    _run(["gh", "issue", "close", str(issue["number"]), "--reason", "completed",
                          "--comment", close_comment(tasks, prs)], project)
                except subprocess.SubprocessError as exc:
                    print(f"  close failed ({exc}); next sweep retries", flush=True)
                    continue
            closed += 1
        for issue, _ in verdict.close[MAX_CLOSES:]:
            print(f"issue-links  #{issue['number']}: due to close, past the {MAX_CLOSES}-per-sweep cap", flush=True)

    if verdict.orphans and planner_id:
        api.write("POST", "/issues", {
            "title": ORPHAN_TITLE,
            "description": orphan_body(verdict.orphans),
            "status": "todo",
            "priority": "low",
            "assigneeAgentId": planner_id,
            "githubIssues": [{"repo": repo, "number": i["number"]} for i in verdict.orphans],
        }, f"issue-links: file Planner task for {len(verdict.orphans)} uncovered issue(s): "
           + ", ".join(f"#{i['number']}" for i in verdict.orphans))
    return closed, len(verdict.orphans)
