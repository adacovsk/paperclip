"""Cancel the extra copies of a roadmap task filed more than once.

`section-claims.py` refuses a duplicate when the Planner files and when promotion
picks a backlog task, but nothing revisits the copies that got past it: a `blocked`
task never reaches promotion, and promotion itself cancels only a twin of work
already in flight or done. Two blocked copies of one batch therefore held each other
indefinitely; one sweep found seventeen such groups, several holding on their own
twin, and every one of them had to be cancelled by hand.

Each sweep groups live top-level tasks by title, keeps the most advanced copy, and
cancels the others when they are `backlog` or `blocked`, unassigned, and their branch
carries no commits. A copy with commits is reported and left alone: picking which of
two pieces of work survives is a reviewer's call, not a title match's. Holds that named
a cancelled copy are re-pointed at the survivor in the same sweep, because a hold on a
cancelled task reads as released, and the release sweep would otherwise free work that
is still waiting.
"""

from __future__ import annotations

import importlib.util
import re
import subprocess
from datetime import datetime, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
_spec = importlib.util.spec_from_file_location("section_claims", HERE.parent / "coordinator" / "section-claims.py")
section_claims = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(section_claims)

#: How far along a copy is; the highest survives. Ties keep the oldest filing.
RANK = {"done": 5, "in_review": 4, "in_progress": 3, "todo": 2, "backlog": 1, "blocked": 0}
CANCELLABLE = {"backlog", "blocked"}
#: A truncated title shorter than this is too generic to call a match on its own.
MIN_WORDS = 6
_SECTION = re.compile(r"§\s*(\d+(?:\.\d+)+)")
_TASK_REF = re.compile(r"\bAA-\d+\b")


def _prefix(short: list[str], long: list[str]) -> bool:
    """Whether `short` is `long` cut off, possibly mid-word.

    Older filings were sliced at 80 characters, so one copy's title can end inside a
    word the other spells out. A cut number is not accepted as a prefix: `batch 1`
    against `batch 10` is two different batches, not one truncated.
    """
    if len(short) < MIN_WORDS or len(short) > len(long) or short[:-1] != long[: len(short) - 1]:
        return False
    last, there = short[-1], long[len(short) - 1]
    return last == there or (not last.isdigit() and there.startswith(last))


def same_work(a: str, b: str) -> bool:
    sa, sb = set(_SECTION.findall(a)), set(_SECTION.findall(b))
    if sa and sb and not sa & sb:
        return False
    wa, wb = section_claims.normalise(a).split(), section_claims.normalise(b).split()
    if not wa or not wb:
        return False
    short, long = sorted((wa, wb), key=len)
    return short == long or _prefix(short, long)


def is_candidate(issue: dict, now: datetime, days: int = 7) -> bool:
    if section_claims.is_stage(issue):
        return False
    return section_claims.is_live(issue, days, now)


def groups(issues: list[dict]) -> list[list[dict]]:
    """Copies of the same work, each group of two or more, in filing order."""
    ordered = sorted(issues, key=lambda i: i["createdAt"])
    parent = list(range(len(ordered)))

    def root(i: int) -> int:
        while parent[i] != i:
            parent[i] = parent[parent[i]]
            i = parent[i]
        return i

    for i, a in enumerate(ordered):
        for j in range(i + 1, len(ordered)):
            if same_work(a["title"], ordered[j]["title"]):
                parent[root(j)] = root(i)
    found: dict[int, list[dict]] = {}
    for i, issue in enumerate(ordered):
        found.setdefault(root(i), []).append(issue)
    return [g for g in found.values() if len(g) > 1]


def survivor(group: list[dict], ahead: dict[str, int]) -> dict:
    """The most advanced copy; commits break a status tie, then the oldest filing wins."""
    return max(group, key=lambda i: (RANK.get(i["status"], -1), ahead.get(i["identifier"], 0) > 0,
                                     -datetime.fromisoformat(i["createdAt"].replace("Z", "+00:00")).timestamp()))


def plan(group: list[dict], ahead: dict[str, int]) -> tuple[dict, list[dict], list[dict]]:
    """(kept copy, copies to cancel, copies left alone because they carry work)."""
    keep = survivor(group, ahead)
    cancel, left = [], []
    for issue in group:
        if issue is keep or issue["status"] not in CANCELLABLE or issue.get("assigneeAgentId"):
            continue
        (left if ahead.get(issue["identifier"], 0) else cancel).append(issue)
    return keep, cancel, left


def repoint(hold: str, moved: dict[str, str]) -> str | None:
    """The hold's first line with cancelled copies swapped for their survivors, or None."""
    line = hold.strip().split("\n", 1)[0]
    if not line.startswith("Held:"):
        return None
    hits = [t for t in dict.fromkeys(_TASK_REF.findall(line)) if t in moved]
    if not hits:
        return None
    for t in hits:
        line = re.sub(rf"\b{t}\b", moved[t], line)
    return f"{line}\n\n(Re-pointed: {', '.join(hits)} cancelled as a duplicate.)"


def commits_ahead(project: Path, ident: str) -> int:
    """Commits on the task's local branch past origin/main; 0 when it has no branch."""
    out = subprocess.run(["git", "-C", str(project), "rev-list", "--count", f"origin/main..task/{ident}"],
                         capture_output=True, text=True, timeout=60)
    return int(out.stdout.strip() or 0) if out.returncode == 0 else 0


def sweep(api, project: Path) -> int:
    """Cancel duplicate copies and re-point holds on them. Returns how many were cancelled."""
    now = datetime.now(timezone.utc)
    live = [i for i in api.issues(status="backlog,todo,in_progress,in_review,blocked,done") if is_candidate(i, now)]
    moved: dict[str, str] = {}
    for group in groups(live):
        ahead = {i["identifier"]: commits_ahead(project, i["identifier"]) for i in group}
        keep, cancel, left = plan(group, ahead)
        for issue in left:
            print(f"dedupe  {issue['identifier']}: duplicate of {keep['identifier']} but its branch "
                  f"has {ahead[issue['identifier']]} commit(s); left for the Coordinator", flush=True)
        for issue in cancel:
            api.set_status(issue, {"status": "cancelled"},
                           f"Cancelled as a duplicate of {keep['identifier']} ({keep['status']}): the same work "
                           f"filed twice. {keep['identifier']} is the copy kept; this one has no commits.",
                           f"dedupe  {issue['identifier']}: cancel, duplicate of {keep['identifier']}")
            moved[issue["identifier"]] = keep["identifier"]
    if not moved:
        return 0
    for issue in api.issues(status="blocked"):
        comments = api.get(f"/issues/{issue['id']}/comments") or []
        newest = max(comments, key=lambda c: c["createdAt"], default=None)
        line = repoint((newest or {}).get("body") or "", moved)
        if line and issue["identifier"] not in moved:
            api.write("POST", f"/issues/{issue['id']}/comments", {"body": line},
                      f"dedupe  {issue['identifier']}: hold re-pointed: {line.split(chr(10), 1)[0][:100]}")
    return len(moved)
