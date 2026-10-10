"""Backlog promotion for the Dispatcher: the mechanical half of the Coordinator's step 5.

Promotion was prose in the Coordinator's instructions, and fires that ran out of
budget skipped it: with promotion open and every Worker slot free, the backlog did
not move for hours. The checks that decide a promotion are mechanical, so they run
here on every sweep. A candidate is promoted only when every one of them passes
on evidence a script can read:

  section-claims.py      the duplicate-dispatch check (claimed -> cancel; unreadable -> skip)
  Removes: keys          every key already gone from main's allowlists -> cancel as done;
                         a key another live task also removes -> hold until it merges
  judgment               a stated ordering, a reference to another task, a section no
                         longer on the roadmap, or no paths to measure -> left for the
                         Coordinator, which still owns step 5 for those
  split                  a file split while too many unlanded branches edit that file
                         -> hold until the oldest of them merges
  contention             a path at `writer_threshold` in-flight writers -> hold until
                         one of them opens its PR

Then the Coordinator's write order: allocate and verify the worktree, PATCH the
`worktree:` line and status, and set the Worker assignee last, because the
assignee write is the wake.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
from dataclasses import dataclass, field
from pathlib import Path

HERE = Path(__file__).resolve().parent
COORDINATOR = HERE.parent / "coordinator"
#: Unlanded branches a split may conflict with before it waits. A split rewrites
#: the whole file, so every branch still editing it needs a port-style rebase;
#: landed while dozens were open, one split cost 10-20 rebases.
SPLIT_MAX_UNLANDED = int(os.environ.get("DISPATCHER_SPLIT_MAX_UNLANDED", 2))
#: Candidates examined per sweep. Each costs two task searches, and the oldest
#: are the ones promotion owes first.
MAX_EXAMINED = int(os.environ.get("DISPATCHER_PROMOTE_EXAMINED", 40))

_TICK = re.compile(r"`([^`\n]+)`")
_PATH_EXT = re.compile(r"\.(rs|json|txt|py|toml|md|sh|ron|png)$")
_REMOVES = re.compile(r"Removes?:\s*(.+?)(?:\.\s|\.$|\n|$)", re.S)
_KEY = re.compile(r"^[a-z][a-z0-9_]*(?::[a-z0-9_]+)?$")
#: An ordering the task states but cannot be checked without reading the roadmap.
_ORDERING = re.compile(
    r"\b(?:after|once|until)\s+(?:§\s*\d|batch(?:es)?\s+\d|AA-\d)|\bbatch(?:es)?\s+\d+[^.\n]{0,40}\b(?:lands?|merges?|landing)\b",
    re.I,
)
_TASK_REF = re.compile(r"\bAA-\d+\b")
_SECTION = re.compile(r"§\s*(\d+(?:\.\d+)+)")
_SPLIT = re.compile(r"\bsplit\s+`?([\w./-]+\.rs)`?", re.I)


@dataclass(frozen=True)
class Verdict:
    action: str  # "promote" | "cancel" | "hold" | "judgment"
    reason: str
    blocker: str | None = None
    hold_kind: str = "merges"  # "merges" | "opens its PR"


@dataclass
class Board:
    """What a candidate is measured against, read once per sweep."""

    #: path -> identifiers of in-flight parents whose branch changes it
    in_flight: dict[str, set[str]] = field(default_factory=dict)
    #: parents still being written: a live Worker, Reviewer or Architect stage, no open PR.
    #: A parent parked on a conflict or a merge is waiting, not writing.
    writing: set[str] = field(default_factory=set)
    #: path -> identifiers of every unlanded parent whose branch changes it, oldest first
    unlanded: dict[str, list[str]] = field(default_factory=dict)
    #: Removes: keys of live, not-done tasks -> their identifiers
    live_keys: dict[str, set[str]] = field(default_factory=dict)
    roadmap: str = ""
    writer_threshold: int = 2


def candidate_paths(body: str) -> list[str]:
    """Backticked tokens that name a file or directory."""
    out = []
    for tok in _TICK.findall(body):
        tok = tok.strip().rstrip(":,")
        if " " in tok or tok.startswith(("docs/ROADMAP", "docs/roadmap/")):
            continue
        if "/" in tok or _PATH_EXT.search(tok):
            if tok not in out:
                out.append(tok)
    return out


def removes_keys(body: str) -> list[str]:
    """Keys a batch task says it retires (`Removes: `a`, `b` (in `x.txt`)`)."""
    keys = []
    for clause in _REMOVES.findall(body):
        for tok in _TICK.findall(clause):
            if _KEY.match(tok) and tok not in keys:
                keys.append(tok)
    return keys


def touches(token: str, path: str) -> bool:
    """Whether a task's path token names `path`. A bare file name matches any directory."""
    token = token.rstrip("/")
    if path == token or path.startswith(token + "/"):
        return True
    return "/" not in token and path.endswith("/" + token)


def too_broad(token: str) -> bool:
    """A directory near the root (`src/`, `src/components/`) names most of the tree, not an edit surface."""
    return not _PATH_EXT.search(token) and len([p for p in token.split("/") if p]) < 3


def writers(token: str, files: dict[str, set[str] | list[str]]) -> list[str]:
    found: list[str] = []
    for path, ids in files.items():
        if touches(token, path):
            found += [i for i in ids if i not in found]
    return found


def judgment_reasons(issue: dict, body: str, roadmap: str, closed: set[str] = frozenset()) -> list[str]:
    """Why a candidate needs the Coordinator. A reference to a task already closed is history."""
    reasons = []
    if _ORDERING.search(body):
        reasons.append("states an ordering on other work")
    if [t for t in _TASK_REF.findall(body) if t != issue["identifier"] and t not in closed]:
        reasons.append("refers to an open task")
    m = _SECTION.search(issue["title"])
    if m and roadmap and not re.search(rf"§\s*{re.escape(m.group(1))}(?![\d.])", roadmap):
        reasons.append(f"§{m.group(1)} is no longer on the roadmap")
    if not candidate_paths(body):
        reasons.append("names no paths to measure contention against")
    return reasons


def judge(issue: dict, body: str, board: Board, claims: tuple[int, str],
          keys_on_main: dict[str, bool], closed: set[str] = frozenset()) -> Verdict:
    """Decide one backlog candidate. `claims` is section-claims.py's (exit, output)."""
    code, out = claims
    if code == 1:
        # Only a same-title claim by work already in flight or done is a duplicate a
        # script may cancel. A section-number claim is what every other batch of a
        # multi-batch front makes, and a claim by another backlog task leaves which of
        # the two to keep open; both are the Coordinator's to read.
        rows = [line.split("\t") for line in out.strip().splitlines() if line.count("\t") >= 2]
        dup = [r for r in rows if r[2] == "same title" and r[1] != "backlog"]
        if dup:
            return Verdict("cancel", f"duplicate of {dup[0][0]} ({dup[0][1]}, same title)")
        if any(r[2] == "same title" for r in rows):
            return Verdict("judgment", "another backlog task has the same title")
        # Sibling batches of one front: one in flight at a time, the next once it
        # opens its PR -- the hold the Coordinator writes for a same-shaped batch.
        live = [r for r in rows if r[1] in ("todo", "in_progress") or r[0] in board.writing]
        if live:
            return Verdict("hold", f"{live[0][0]} is the batch of this section in flight; one at a time",
                           live[0][0], "opens its PR")
    elif code != 0:
        return Verdict("judgment", "section-claims.py could not run")

    keys = removes_keys(body)
    if keys and not any(keys_on_main.get(k, True) for k in keys):
        return Verdict("cancel", "superseded — every key it removes is already gone from main's allowlists: "
                       + ", ".join(f"`{k}`" for k in keys))
    for k in keys:
        others = sorted(board.live_keys.get(k, set()) - {issue["identifier"]})
        if others:
            return Verdict("hold", f"`{k}` is also removed by {others[0]}", others[0], "merges")

    reasons = judgment_reasons(issue, body, board.roadmap, closed)
    if reasons:
        return Verdict("judgment", "; ".join(reasons))

    m = _SPLIT.search(issue["title"])
    if m:
        open_branches = [i for i in writers(m.group(1), board.unlanded) if i != issue["identifier"]]
        if len(open_branches) > SPLIT_MAX_UNLANDED:
            return Verdict(
                "hold",
                f"split of `{m.group(1)}` would conflict with {len(open_branches)} unlanded branches "
                f"(limit {SPLIT_MAX_UNLANDED})",
                open_branches[0], "merges",
            )

    for token in candidate_paths(body):
        if too_broad(token):
            continue
        live = [i for i in writers(token, board.in_flight) if i != issue["identifier"]]
        if len(live) >= board.writer_threshold:
            return Verdict("hold", f"`{token}` has {len(live)} live writers", live[0], "opens its PR")
    return Verdict("promote", "checks clean")


# --------------------------------------------------------------------------- I/O


def git(cwd: Path, *args: str) -> str:
    return subprocess.run(["git", "-C", str(cwd), *args], capture_output=True, text=True,
                          check=True, timeout=120).stdout


def branch_files(wt: Path) -> set[str]:
    """Files a worktree's branch changes, committed (three dots) and uncommitted."""
    try:
        return set((git(wt, "diff", "--name-only", "origin/main...HEAD")
                    + git(wt, "diff", "--name-only", "HEAD")).split())
    except subprocess.SubprocessError:
        return set()


def read_board(api, project: Path, pr_heads: dict[str, str], writer_threshold: int) -> Board:
    board = Board(writer_threshold=writer_threshold)
    open_parents = [
        i for i in api.issues(status="todo,in_progress,in_review,blocked")
        if not i.get("parentId") and not i["title"].startswith(("Review:", "Verify:", "ci-fix:", "Rebase "))
    ]
    stage_open = {
        c["parentId"] for c in api.issues(status="todo,in_progress,in_review")
        if c.get("parentId") and c["title"].startswith(("Review:", "Verify:", "Rebase ", "ci-fix:"))
    }
    for parent in sorted(open_parents, key=lambda i: i["createdAt"]):
        ident = parent["identifier"]
        wt = project / ".paperclip" / "worktrees" / ident
        if not wt.is_dir():
            continue
        files = branch_files(wt)
        for f in files:
            board.unlanded.setdefault(f, []).append(ident)
        # In flight = still being written. A branch whose PR is open holds nothing.
        writing = parent["status"] in ("todo", "in_progress") or parent["id"] in stage_open
        if writing and f"task/{ident}" not in pr_heads:
            board.writing.add(ident)
            for f in files:
                board.in_flight.setdefault(f, set()).add(ident)
    for parent in open_parents:
        if parent["status"] == "blocked" and not parent.get("assigneeAgentId"):
            continue  # a held task is not writing anything yet
        full = api.get(f"/issues/{parent['id']}")
        for k in removes_keys(full.get("description") or ""):
            board.live_keys.setdefault(k, set()).add(parent["identifier"])
    try:
        board.roadmap = git(project, "show", "origin/main:docs/ROADMAP.md")
    except subprocess.SubprocessError:
        board.roadmap = ""
    return board


def keys_still_on_main(project: Path, keys: list[str]) -> dict[str, bool]:
    """Whether each key still appears in an allowlist or stub file under scripts/ on main."""
    present = {}
    for k in keys:
        try:
            hits = git(project, "grep", "-l", "-w", "-F", k, "origin/main", "--", "scripts/")
        except subprocess.CalledProcessError:
            hits = ""
        present[k] = any(re.search(r"allowlist|stub", h) for h in hits.splitlines())
    return present


def run_claims(issue: dict, body: str) -> tuple[int, str]:
    m = _SECTION.search(issue["title"]) or _SECTION.search(body)
    if not m:
        return 0, ""  # no section to claim; the title match needs one to search by
    args = [str(COORDINATOR / "section-claims.py"), m.group(1), "--title", issue["title"],
            "--exclude", issue["identifier"]]
    if re.search(r"Section:\s*§[\d.]+\s*\(slice\)", body):
        args += ["--slice", "--paths", *candidate_paths(body)]
    out = subprocess.run(args, capture_output=True, text=True, timeout=120)
    return out.returncode, out.stdout + out.stderr


def pace(apply: bool) -> dict:
    out = subprocess.run([str(COORDINATOR / "pace-scale.py"), *(["--apply"] if apply else [])],
                         capture_output=True, text=True, timeout=120)
    try:
        return json.loads(out.stdout)
    except ValueError:
        return {}


def task_status(api, ident: str, cache: dict[str, str | None]) -> str | None:
    if ident not in cache:
        found = [i for i in api.issues(q=ident) if i.get("identifier") == ident]
        cache[ident] = found[0]["status"] if found else None
    return cache[ident]


def hold_line(v: Verdict) -> str:
    return f"Held: until {v.blocker} {v.hold_kind} — {v.reason}"


def promote(api, agents: dict, project: Path, pr_heads: dict[str, str]) -> tuple[int, int]:
    """Promote backlog candidates into free Worker slots. Returns (promoted, left for the Coordinator)."""
    knobs = pace(apply=not api.dry_run)
    if not knobs:
        print("promote pace-scale unreadable — promotion left to the Coordinator", flush=True)
        return 0, 0
    worker = next(a for a in api.get(f"/companies/{api.company}/agents") if a["name"] == "Worker")
    slots = ((worker.get("runtimeConfig") or {}).get("heartbeat") or {}).get("maxConcurrentRuns") or 0
    running = api.issues(status="todo,in_progress", assigneeAgentId=agents["Worker"])
    new_work = [i for i in running if not i["title"].startswith("Rebase ")]
    budget = min(slots - len(running), knobs.get("promote_slots", 0) - len(new_work))
    if budget <= 0:
        return 0, 0

    backlog = sorted(
        (i for i in api.issues(status="backlog") if not i.get("assigneeAgentId")),
        key=lambda i: i["createdAt"],
    )[:MAX_EXAMINED]
    if not backlog:
        return 0, 0
    try:
        git(project, "fetch", "-q", "origin", "main")
    except subprocess.SubprocessError:
        print("promote cannot fetch origin/main — promotion left to the Coordinator", flush=True)
        return 0, 0
    board = read_board(api, project, pr_heads, knobs.get("writer_threshold", 2))

    promoted = judged = 0
    statuses: dict[str, str | None] = {}
    for issue in backlog:
        if promoted >= budget:
            break
        body = api.get(f"/issues/{issue['id']}").get("description") or ""
        keys = removes_keys(body)
        refs = {t for t in _TASK_REF.findall(body) if t != issue["identifier"]}
        closed = {t for t in refs if task_status(api, t, statuses) in ("done", "cancelled")}
        v = judge(issue, body, board, run_claims(issue, body), keys_still_on_main(project, keys), closed)
        ident = issue["identifier"]
        if v.action == "judgment":
            judged += 1
            print(f"promote {ident}: left for the Coordinator ({v.reason})", flush=True)
        elif v.action == "cancel":
            api.set_status(issue, {"status": "cancelled"}, f"Cancelled at promotion: {v.reason}.",
                           f"promote {ident}: cancel ({v.reason[:80]})")
        elif v.action == "hold":
            api.set_status(issue, {"status": "blocked", "assigneeAgentId": None}, hold_line(v),
                           f"promote {ident}: hold ({v.reason[:80]})")
        elif allocate_and_assign(api, agents, project, issue, body):
            promoted += 1
            for token in candidate_paths(body):
                board.in_flight.setdefault(token, set()).add(ident)
    return promoted, judged


def allocate_and_assign(api, agents: dict, project: Path, issue: dict, body: str) -> bool:
    ident = issue["identifier"]
    wt, branch = f".paperclip/worktrees/{ident}", f"task/{ident}"
    if api.dry_run:
        print(f"DRY promote {ident}: allocate {wt}, todo, assign Worker", flush=True)
        return True
    try:
        if not (project / wt).is_dir():
            git(project, "worktree", "add", wt, "-b", branch, "origin/main")
        ok = git(project / wt, "branch", "--show-current").strip() == branch
    except subprocess.SubprocessError as exc:
        ok, reason = False, str(exc)[:120]
    else:
        reason = "worktree is on the wrong branch"
    if not ok:
        api.set_status(issue, {"status": "blocked", "assigneeAgentId": None},
                       f"Held: worktree allocation failed — {reason}",
                       f"promote {ident}: worktree allocation failed")
        return False
    if not re.search(r"(?m)^worktree:", body):
        body = f"worktree: {wt}\nbranch:   {branch}\n\n{body}"
    api.write("PATCH", f"/issues/{issue['id']}",
              {"description": body, "status": "todo",
               "comment": "Promoted backlog -> todo by the Dispatcher: section-claims clean, no "
                          "superseded or shared Removes: keys, no live-writer contention on its paths."},
              f"promote {ident}: todo ({wt})")
    # Last: the assignee change is the Worker's wake.
    api.write("PATCH", f"/issues/{issue['id']}", {"assigneeAgentId": agents["Worker"]},
              f"promote {ident}: assign Worker")
    return True
