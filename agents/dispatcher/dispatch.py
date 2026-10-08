#!/usr/bin/env python3
"""Advance finished pipeline stages without a model.

The Advancer is a `process` agent: the server routes every stage-completion
wake to it instead of the Coordinator (`stageAdvancerIdFor`). Those wakes were
nearly nine in ten Coordinator runs, and most of them resolved through the
mechanical rows of the Coordinator's stage table at the cost of re-reading its
whole instruction set. This script runs those rows directly:

  Worker done, committed, clean tree      -> Review subtask
  Reviewer done, needs-build              -> Verify subtask
  Reviewer done, data-only, data touched  -> Verify subtask
  rebase finished, merge-tree clean       -> close it, re-Verify the parent
  held Verify, capacity free              -> dispatch it
  `Held: waiting on <id>`, <id> resolved  -> back to backlog

Everything else that is waiting on the Coordinator -- a dirty tree, no commits,
a chain, a finished rebase, an unlabeled task -- is handed off in ONE wake, and
only when its state changed since the last hand-off. The list itself is written
to HANDOFF_FILE for the Coordinator to read: a wake payload naming an issue
would make the run task-scoped and take that task's execution lock.
That wake also asks for a slot refill when Worker slots are free and backlog
holds work, because promotion needs the contention and hold rules a script
should not guess at.

Wakes coalesce per agent, so a run cannot trust its payload to name every task
that advanced. It sweeps the board instead; every action is idempotent (the
server's `(parentId, dedupeKey)` index makes a duplicate create return the
existing subtask).

    advance.py            sweep and act
    advance.py --dry-run  print the actions, write nothing
"""

from __future__ import annotations

import argparse
import concurrent.futures
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request
from dataclasses import dataclass, field
from pathlib import Path

HERE = Path(__file__).resolve().parent
STATE_DIR = Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache")) / "paperclip-advancer"
HANDOFF_FILE = STATE_DIR / "handoff.json"
#: Hold release reads every held task's comments; once per window is plenty.
HOLD_SCAN_INTERVAL = float(os.environ.get("ADVANCER_HOLD_SCAN_SECONDS", 300))
#: A refill wake the Coordinator just answered needs no repeat inside this window.
REFILL_INTERVAL = float(os.environ.get("ADVANCER_REFILL_SECONDS", 300))

STAGE_KEYS = {"review": "review", "verify": "verify", "ci-fix": "verify"}
STAGE_PREFIXES = {"Review:": "review", "Verify:": "verify", "ci-fix:": "verify", "Rebase ": "rebase"}
OPEN = {"backlog", "todo", "in_progress", "in_review", "blocked"}
DATA_PATH = re.compile(r"^assets/(data|locales)/")
HELD_WAITING = re.compile(r"^Held: waiting on ([A-Z]+-\d+)")
HELD_VERIFY = "Intended assignee: Architect (held"


# --------------------------------------------------------------------------- decisions


@dataclass(frozen=True)
class GitState:
    exists: bool
    dirty: bool = False
    ahead: int = 0
    head: str = ""
    changed: tuple[str, ...] = ()
    merges_clean: bool = False


@dataclass(frozen=True)
class Decision:
    kind: str  # "review" | "verify" | "reverify" | "close-rebase" | "handoff" | "skip"
    reason: str


def stage_of(child: dict) -> str | None:
    key = STAGE_KEYS.get(child.get("dedupeKey") or "")
    if key:
        return key
    for prefix, stage in STAGE_PREFIXES.items():
        if child["title"].startswith(prefix):
            return stage
    return None


def label_names(issue: dict) -> set[str]:
    return {label["name"] for label in issue.get("labels") or []}


def finished_rebase(child: dict) -> bool:
    # A Worker never marks its own run done: a finished rebase parks at `in_review`.
    return stage_of(child) == "rebase" and child["status"] == "in_review"


def decide(parent: dict, children: list[dict], git: GitState, pr_head: str | None = None) -> Decision:
    """One parent -> what its next stage is.

    Pure, so the signal table is testable without an API or a worktree.
    """
    stages = sorted(
        ((stage_of(c), c) for c in children if stage_of(c)),
        key=lambda pair: pair[1]["createdAt"],
    )
    if any(c["status"] in OPEN and not finished_rebase(c) for _, c in stages):
        return Decision("skip", "a stage is still open")
    if not git.exists:
        return Decision("handoff", "no worktree")

    if stages and finished_rebase(stages[-1][1]):
        # The rebase invalidated whatever verify ran before it, so the next
        # stage is a fresh one -- but only once the conflict is really gone.
        if parent["status"] != "in_review":
            return Decision("handoff", f"rebase finished on a {parent['status']} parent")
        if git.dirty or not git.merges_clean:
            return Decision("handoff", "rebase finished but the branch still does not merge cleanly")
        if pr_head and pr_head == git.head:
            return Decision("close-rebase", "rebase finished and the open PR already carries it")
        return Decision("reverify", "rebase finished and merge-tree is clean")

    if pr_head:
        # Landed work waits on a human merge; the merge sweep owns it, whatever
        # stage ran last (a re-review after the verify is a normal history).
        return Decision("skip", "PR open")

    if not stages:
        if git.dirty:
            return Decision("handoff", "Worker finished on a dirty tree")
        if git.ahead == 0:
            return Decision("handoff", "Worker finished with no commits")
        if re.search(r"(?m)^\s*Chain:\s*\d+\s*steps", parent.get("description") or ""):
            return Decision("handoff", "chain task")
        return Decision("review", "Worker committed on a clean tree")

    stage, last = stages[-1]
    if stage == "review" and last["status"] == "done":
        labels = label_names(parent)
        if "needs-build" in labels:
            return Decision("verify", "Reviewer done, needs-build")
        if "data-only" in labels:
            if any(DATA_PATH.match(path) for path in git.changed):
                return Decision("verify", "Reviewer done, data-only touching data Rust loads")
            return Decision("handoff", "Reviewer done, data-only with no data path")
        return Decision("handoff", "Reviewer done, no pipeline label")
    if stage == "verify":
        # Landing and the merge sweep own everything after a verify.
        return Decision("skip", "verify finished; landing owns it")
    return Decision("handoff", f"last stage {stage} ended {last['status']}")


def held_waiting_on(comment: str) -> str | None:
    m = HELD_WAITING.match(comment.strip())
    return m.group(1) if m else None


def hold_resolved(blocker: dict | None, blocker_pr_open: bool) -> str | None:
    """Why a `Held: waiting on <id>` hold is released, or None to keep it."""
    if blocker is None:
        return None
    if blocker["status"] in ("done", "cancelled"):
        return f"{blocker['identifier']} is {blocker['status']}"
    if blocker_pr_open:
        return f"{blocker['identifier']} has an open PR, so it is no longer in flight"
    return None


def handoff_signature(parent: dict, children: list[dict], git: GitState) -> str:
    newest = max((c["updatedAt"] for c in children), default="")
    return f"{parent['status']}|{git.head}|{git.dirty}|{newest}"


# --------------------------------------------------------------------------- I/O


class Api:
    def __init__(self, dry_run: bool):
        self.base = os.environ.get("PAPERCLIP_API_URL", "http://127.0.0.1:3100").rstrip("/") + "/api"
        self.company = os.environ["PAPERCLIP_COMPANY_ID"]
        self.dry_run = dry_run
        self.headers = {"Content-Type": "application/json"}
        if os.environ.get("PAPERCLIP_API_KEY"):
            self.headers["Authorization"] = f"Bearer {os.environ['PAPERCLIP_API_KEY']}"
        if os.environ.get("PAPERCLIP_RUN_ID"):
            self.headers["X-Paperclip-Run-Id"] = os.environ["PAPERCLIP_RUN_ID"]

    def call(self, method: str, path: str, body: dict | None = None):
        req = urllib.request.Request(
            self.base + path,
            data=None if body is None else json.dumps(body).encode(),
            method=method,
            headers=self.headers,
        )
        with urllib.request.urlopen(req, timeout=30) as resp:
            raw = resp.read()
            return json.loads(raw) if raw else None

    def get(self, path: str):
        return self.call("GET", path)

    def write(self, method: str, path: str, body: dict, what: str):
        print(("DRY " if self.dry_run else "") + what, flush=True)
        if self.dry_run:
            return None
        return self.call(method, path, body)

    def issues(self, **query) -> list[dict]:
        qs = "&".join(f"{k}={v}" for k, v in query.items())
        return self.get(f"/companies/{self.company}/issues?{qs}")

    def set_status(self, issue: dict, body: dict, comment: str, what: str):
        """Status and its reason in one call; on error, comment first, then PATCH."""
        try:
            self.write("PATCH", f"/issues/{issue['id']}", {**body, "comment": comment}, what)
        except urllib.error.HTTPError:
            self.write("POST", f"/issues/{issue['id']}/comments", {"body": comment}, f"  comment on {issue['identifier']}")
            self.write("PATCH", f"/issues/{issue['id']}", body, f"  retry {what}")


def git(worktree: Path, *args: str) -> str:
    return subprocess.run(
        ["git", "-C", str(worktree), *args], capture_output=True, text=True, check=True, timeout=60
    ).stdout


def git_state(project: Path, identifier: str) -> GitState:
    wt = project / ".paperclip" / "worktrees" / identifier
    if not wt.is_dir():
        return GitState(exists=False)
    try:
        dirty = bool(git(wt, "status", "--porcelain").strip())
        ahead = int(git(wt, "rev-list", "--count", "origin/main..HEAD").strip() or 0)
        head = git(wt, "rev-parse", "HEAD").strip()
        changed = tuple(git(wt, "diff", "--name-only", "origin/main...HEAD").split())
        merges_clean = subprocess.run(
            ["git", "-C", str(wt), "merge-tree", "--write-tree", "origin/main", "HEAD"],
            capture_output=True, timeout=60,
        ).returncode == 0
    except (subprocess.SubprocessError, ValueError):
        return GitState(exists=False)
    return GitState(exists=True, dirty=dirty, ahead=ahead, head=head, changed=changed, merges_clean=merges_clean)


def open_pr_heads(project: Path) -> dict[str, str]:
    """Open PRs as {head branch: head commit}."""
    out = subprocess.run(
        ["gh", "pr", "list", "--state", "open", "--limit", "500", "--json", "headRefName,headRefOid"],
        cwd=project, capture_output=True, text=True, timeout=60, check=True,
    ).stdout
    return {pr["headRefName"]: pr["headRefOid"] for pr in json.loads(out)}


def verify_capacity() -> int | None:
    """Verifies that may still be dispatched now; None means unbounded (cloud lane open)."""
    lane = subprocess.run(
        [sys.executable, str(HERE.parent / "architect" / "cloud-pace.py")],
        capture_output=True, text=True, timeout=60,
    ).stdout.strip()
    if lane == "1":
        return None
    try:
        slots = int(Path("/tmp/cargo-sem.slots").read_text().strip())
    except (OSError, ValueError):
        slots = 2
    live = subprocess.run(
        [str(HERE.parent / "architect" / "verify-census.sh")], capture_output=True, text=True, timeout=60,
    ).stdout.split()
    return max(0, 2 * slots - len(live))


def load_state(name: str) -> dict:
    try:
        return json.loads((STATE_DIR / name).read_text())
    except (OSError, ValueError):
        return {}


def save_state(name: str, data: dict, dry_run: bool) -> None:
    if dry_run:
        return
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    (STATE_DIR / name).write_text(json.dumps(data))


# --------------------------------------------------------------------------- actions


def worktree_lines(identifier: str) -> tuple[str, str]:
    return f".paperclip/worktrees/{identifier}", f"task/{identifier}"


def issue_link(identifier: str) -> str:
    return f"[{identifier}](/{identifier.split('-')[0]}/issues/{identifier})"


def create_review(api: Api, agents: dict, parent: dict, git_st: GitState):
    wt, branch = worktree_lines(parent["identifier"])
    label = next(iter(label_names(parent) & {"needs-build", "data-only"}), "none")
    files = "\n".join(f"- {p}" for p in git_st.changed) or "- (none)"
    body = (
        f"What: review {branch} against the parent's What/Done-when.\n"
        f"Why: Worker stage complete, commit {git_st.head[:9]}.\n"
        f"Where: worktree {wt} (branch {branch}).\n"
        f"Changed files:\n{files}\n"
        f"Done-when: diff satisfies parent Done-when; Reviewer commits any fixes.\n"
        f"Label: {label}\n\n"
        f"worktree: {wt} (branch {branch})\n"
    )
    api.write(
        "POST",
        f"/companies/{api.company}/issues",
        {
            "title": f"Review: {parent['identifier']} {parent['title']}"[:200],
            "description": body,
            "status": "in_review",
            "priority": parent.get("priority") or "medium",
            "parentId": parent["id"],
            "goalId": parent.get("goalId"),
            "assigneeAgentId": agents["Reviewer"],
            "dedupeKey": "review",
        },
        f"review  {parent['identifier']}: create Review subtask",
    )


def create_verify(api: Api, agents: dict, parent: dict, after: dict, git_st: GitState, dispatch: bool):
    wt, branch = worktree_lines(parent["identifier"])
    held = "" if dispatch else "\nIntended assignee: Architect (held — no verify capacity free)\n"
    where = ", ".join(f"`{p}`" for p in git_st.changed) or "(see branch)"
    body = (
        f"worktree: {wt}\nbranch:   {branch}\n\n"
        "**What** — Run `cargo clippy --all-targets` and `cargo test` against the worktree above, "
        "fix what they report, commit, and open the PR.\n\n"
        f"**Why** — {issue_link(parent['identifier'])}: {parent['title']}. "
        f"{after['title'].split(':')[0].split()[0]} {issue_link(after['identifier'])} is done.\n\n"
        f"**Where** — {where}\n{held}"
    )
    label_ids = [l["id"] for l in parent.get("labels") or [] if l["name"] == "needs-build"]
    api.write(
        "POST",
        f"/companies/{api.company}/issues",
        {
            "title": f"Verify: {parent['identifier']} {parent['title']}"[:200],
            "description": body,
            "status": "in_review" if dispatch else "todo",
            "priority": parent.get("priority") or "medium",
            "parentId": parent["id"],
            "goalId": parent.get("goalId"),
            "assigneeAgentId": agents["Architect"] if dispatch else None,
            "dedupeKey": "verify",
            **({"labelIds": label_ids} if label_ids else {}),
        },
        f"verify  {parent['identifier']}: create Verify subtask ({'dispatched' if dispatch else 'held'})",
    )


# --------------------------------------------------------------------------- sweep


def sweep(api: Api, project: Path) -> None:
    roster = api.get(f"/companies/{api.company}/agents")
    agents = {a["name"]: a["id"] for a in roster}
    worker = next(a for a in roster if a["name"] == "Worker")

    owned = api.issues(status="in_review", assigneeAgentId=agents["Worker"])
    parents = [p for p in owned if not stage_of(p)]
    # A finished rebase's parent may be parked anywhere (a conflict hold blocks
    # it), so it joins the sweep by its child rather than by its own status.
    listed = {p["id"] for p in parents}
    for rebase in owned:
        if finished_rebase(rebase) and rebase.get("parentId") and rebase["parentId"] not in listed:
            listed.add(rebase["parentId"])
            parents.append(api.get(f"/issues/{rebase['parentId']}"))

    def load(parent: dict):
        children = api.issues(parentId=parent["id"])
        if any(stage_of(c) and c["status"] in OPEN and not finished_rebase(c) for c in children):
            return parent, children, None  # a stage is live: no git read needed
        full = api.get(f"/issues/{parent['id']}")
        return full, children, git_state(project, parent["identifier"])

    with concurrent.futures.ThreadPoolExecutor(8) as pool:
        loaded = list(pool.map(load, parents))
    pr_heads = open_pr_heads(project)

    capacity: int | None | str = "unread"  # the probe costs seconds; read it on first use
    handed = load_state("handoffs.json")
    handoff: list[dict] = []
    seen: dict[str, str] = {}

    def take_capacity() -> bool:
        nonlocal capacity
        if capacity == "unread":
            capacity = verify_capacity()
        if capacity is None:
            return True
        if capacity > 0:
            capacity -= 1
            return True
        return False

    def hand_off(issue: dict, sig: str, reason: str) -> None:
        seen[issue["id"]] = sig
        if handed.get(issue["id"]) != sig:
            handoff.append({"identifier": issue["identifier"], "reason": reason})

    # Held verifies first: they waited longest for a build slot.
    for held in sorted(
        (v for v in api.issues(status="todo") if stage_of(v) == "verify" and not v.get("assigneeAgentId")),
        key=lambda v: v["createdAt"],
    ):
        body = api.get(f"/issues/{held['id']}").get("description") or ""
        if HELD_VERIFY not in body or not take_capacity():
            continue
        api.set_status(
            held,
            {"status": "in_review", "assigneeAgentId": agents["Architect"]},
            "Dispatching: verify capacity is free (held at creation for lack of a build slot).",
            f"verify  {held['identifier']}: dispatch held verify",
        )

    for parent, children, git_st in loaded:
        if git_st is None:
            continue
        decision = decide(parent, children, git_st, pr_heads.get(f"task/{parent['identifier']}"))
        if decision.kind == "review":
            create_review(api, agents, parent, git_st)
        elif decision.kind == "verify":
            review = max((c for c in children if stage_of(c) == "review"), key=lambda c: c["createdAt"])
            create_verify(api, agents, parent, review, git_st, take_capacity())
        elif decision.kind in ("reverify", "close-rebase"):
            rebase = max((c for c in children if finished_rebase(c)), key=lambda c: c["createdAt"])
            follow = (
                "The parent needs a fresh verify on the rebased head."
                if decision.kind == "reverify"
                else "The open PR's head is this commit, so nothing further is needed here."
            )
            api.set_status(
                rebase,
                {"status": "done"},
                f"Rebase landed: `merge-tree --write-tree origin/main HEAD` is clean at "
                f"{git_st.head[:9]}, tree clean. {follow}",
                f"rebase  {rebase['identifier']}: close ({decision.reason})",
            )
            if decision.kind == "reverify":
                create_verify(api, agents, parent, rebase, git_st, take_capacity())
        elif decision.kind == "handoff":
            hand_off(parent, handoff_signature(parent, children, git_st), decision.reason)

    released = release_holds(api, pr_heads)

    # Promotion needs the Coordinator's contention rules; ask only when it could promote.
    in_flight = len(api.issues(status="todo,in_progress", assigneeAgentId=agents["Worker"]))
    slots = ((worker.get("runtimeConfig") or {}).get("heartbeat") or {}).get("maxConcurrentRuns") or 0
    backlog = len(api.issues(status="backlog"))
    refill_state = load_state("refill.json")
    refill = (
        slots > in_flight
        and backlog > 0
        and (released > 0 or time.time() - refill_state.get("at", 0) > REFILL_INTERVAL)
    )

    if handoff or refill:
        note = {
            "at": time.time(),
            "handoff": handoff,
            "refill": refill,
            "freeWorkerSlots": max(0, slots - in_flight),
            "backlog": backlog,
        }
        lines = [f"- {h['identifier']}: {h['reason']}" for h in handoff]
        print(("DRY " if api.dry_run else "") + f"wake    Coordinator: {len(handoff)} hand-off(s), refill={refill}")
        for line in lines:
            print("  " + line)
        if not api.dry_run:
            # Accumulate until the Coordinator takes the file (it renames it on
            # read), so two runs between its wakes cannot drop each other's entries.
            pending = {h["identifier"]: h for h in load_state(HANDOFF_FILE.name).get("handoff", [])}
            pending.update({h["identifier"]: h for h in handoff})
            note["handoff"] = list(pending.values())
            save_state(HANDOFF_FILE.name, note, False)
            api.call(
                "POST",
                f"/agents/{agents['Coordinator']}/wakeup",
                {"source": "automation", "triggerDetail": "callback", "reason": "advancer_handoff"},
            )
            if refill:
                save_state("refill.json", {"at": time.time()}, False)
    # Forget tasks that left the hand-off set so a later return re-notifies.
    save_state("handoffs.json", seen, api.dry_run)


def release_holds(api: Api, pr_heads: dict[str, str]) -> int:
    """Release `Held: waiting on <id>` holds whose blocker resolved. Returns how many."""
    state = load_state("holds.json")
    if time.time() - state.get("at", 0) < HOLD_SCAN_INTERVAL:
        return 0
    held = [i for i in api.issues(status="blocked") if not i.get("assigneeAgentId")]

    def latest(issue: dict):
        comments = api.get(f"/issues/{issue['id']}/comments")
        newest = max(comments, key=lambda c: c["createdAt"], default=None)
        return issue, (newest or {}).get("body") or ""

    with concurrent.futures.ThreadPoolExecutor(8) as pool:
        pairs = list(pool.map(latest, held))

    waiting = [(i, body, held_waiting_on(body)) for i, body in pairs]
    waiting = [w for w in waiting if w[2]]
    blockers: dict[str, dict | None] = {}
    released = 0
    for issue, body, blocker_id in waiting:
        if blocker_id not in blockers:
            try:
                blockers[blocker_id] = api.get(f"/issues/{blocker_id}")
            except urllib.error.HTTPError:
                blockers[blocker_id] = None
        why = hold_resolved(blockers[blocker_id], f"task/{blocker_id}" in pr_heads)
        if not why:
            continue
        quoted = body.strip().splitlines()[0]
        api.set_status(
            issue,
            {"status": "backlog"},
            f"Released: {why}.\n\n> {quoted}",
            f"release {issue['identifier']}: {why}",
        )
        released += 1
    save_state("holds.json", {"at": time.time()}, api.dry_run)
    return released


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    project = Path(os.environ["PAPERCLIP_PROJECT"])
    sweep(Api(args.dry_run), project)
    return 0


if __name__ == "__main__":
    sys.exit(main())
