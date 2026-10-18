"""The Facilitator's rule-shaped checks, run on the Dispatcher's sweep instead of nightly.

Three of the Facilitator's steps need no judgment: re-firing a missed wake (§2a),
spotting a wedged per-agent dispatcher (§2b), and finding remote branches whose
work is already on `origin/main` (§7 cases 1-2). As a nightly model run they failed
on the same thing that causes the stalls they exist to clear. Wakes die when the
account's usage limit runs out, and so did the Facilitator, two nights running, while
verify stages sat idle for days with nothing left to re-fire them. A script spends no
model quota and runs every half hour, so a stall lasts one sweep, not a day.

What still needs a reader stays in the Facilitator's sweep: why a toggle did not take,
whether a wedge is new, run productivity, config drift, comment-without-PATCH. This
module writes REPORT_FILE for that sweep to read.

    mechanical.py            run the checks and act
    mechanical.py --dry-run  print the actions, write nothing
"""

from __future__ import annotations

import json
import os
import subprocess
import time
from datetime import datetime
from pathlib import Path

STATE_DIR = Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache")) / "paperclip-dispatcher"
REPORT_FILE = STATE_DIR / "facilitator.json"
TOGGLES_FILE = STATE_DIR / "facilitator-toggles.json"

#: An assigned task this long without a run has missed its wake.
STALL_SECONDS = float(os.environ.get("FACILITATOR_STALL_SECONDS", 2 * 3600))
#: A toggle that did not take is not retried sooner than this. While the usage limit is
#: out every wake fails on start, and re-firing each sweep would only stack failed runs.
RETOGGLE_SECONDS = float(os.environ.get("FACILITATOR_RETOGGLE_SECONDS", 6 * 3600))
#: Toggles without the task moving before it is a rotation bug for the model to file.
TOGGLE_ESCALATE = int(os.environ.get("FACILITATOR_TOGGLE_ESCALATE", 3))
#: At most this many toggles per sweep, oldest stall first; the rest wait one sweep.
TOGGLE_CAP = int(os.environ.get("FACILITATOR_TOGGLE_CAP", 20))
#: Queued runs with none running, oldest older than this, is a wedged dispatcher.
WEDGE_SECONDS = float(os.environ.get("FACILITATOR_WEDGE_SECONDS", 15 * 60))
#: A branch tip younger than this is left alone even when its work is on main: it may
#: be mid-landing, pushed a moment before its PR is opened.
BRANCH_MIN_AGE = float(os.environ.get("FACILITATOR_BRANCH_MIN_AGE_SECONDS", 24 * 3600))
BRANCH_SCAN_SECONDS = float(os.environ.get("FACILITATOR_BRANCH_SCAN_SECONDS", 6 * 3600))
WEDGE_TITLE = "Wedged dispatcher: "
STAGE_PREFIXES = ("Review:", "Verify:", "ci-fix:", "Rebase ")
STAGE_KEYS = {"review", "verify", "ci-fix", "rebase"}


def ts(stamp: str) -> float:
    return datetime.fromisoformat(stamp.replace("Z", "+00:00")).timestamp()


def is_stage(issue: dict) -> bool:
    return (issue.get("dedupeKey") or "") in STAGE_KEYS or issue["title"].startswith(STAGE_PREFIXES)


# --------------------------------------------------------------------------- §2a missed wakes


def missed_wakes(issues: list[dict], live_runs: list[dict], paused: set[str], skip_agent: str | None,
                 now: float, quiet_since=None) -> list[dict]:
    """Assigned tasks whose wake never started a run, oldest stall first.

    A Worker parent `in_review` with no run is waiting on its stage children, which is
    healthy; only a stage, or a task its agent had already taken `in_progress`, is owed
    a run. The Dispatcher's own Verifies wait on a cloud build with no run by design.

    `quiet_since(issue)` is when the task last did anything off the board, or None
    while work it is waiting on is still running: a Verify has no run for the hours
    its build is out, and that is not a stall. It defaults to `updatedAt`.
    """
    live_ids = {r["id"] for r in live_runs}
    live_issues = {r.get("issueId") for r in live_runs if r.get("issueId")}
    out = []
    for issue in issues:
        agent = issue.get("assigneeAgentId")
        if not agent or agent == skip_agent or agent in paused:
            continue
        if issue["status"] not in ("in_review", "in_progress"):
            continue
        if issue["status"] == "in_review" and not is_stage(issue):
            continue
        if issue.get("activeRun") or issue["id"] in live_issues:
            continue
        if issue.get("executionRunId") and issue["executionRunId"] in live_ids:
            continue
        since = ts(issue["updatedAt"])
        if quiet_since:
            off_board = quiet_since(issue)
            if off_board is None:
                continue
            since = max(since, off_board)
        if now - since < STALL_SECONDS:
            continue
        out.append(issue)
    return sorted(out, key=lambda i: i["updatedAt"])


def plan_toggles(stalled: list[dict], history: dict, now: float) -> tuple[list[dict], list[dict], dict]:
    """(tasks to toggle now, tasks whose toggles keep not taking, history to save).

    History is kept only for tasks still stalled, so a task that started moving and
    later stalls again starts its count over.
    """
    keep = {i["id"]: history[i["id"]] for i in stalled if i["id"] in history}
    due = [i for i in stalled if now - keep.get(i["id"], {}).get("at", 0) >= RETOGGLE_SECONDS][:TOGGLE_CAP]
    failing = [i for i in stalled if keep.get(i["id"], {}).get("count", 0) >= TOGGLE_ESCALATE]
    for issue in due:
        keep[issue["id"]] = {"at": now, "count": keep.get(issue["id"], {}).get("count", 0) + 1}
    return due, failing, keep


def toggle(api, issue: dict) -> None:
    """Re-fire the wake: it fires on an assignee *change*, so through null and back."""
    agent = issue["assigneeAgentId"]
    api.write("PATCH", f"/issues/{issue['id']}", {"assigneeAgentId": None},
              f"wake    {issue['identifier']}: unassign (no run for {stall_hours(issue):.0f}h)")
    api.write("PATCH", f"/issues/{issue['id']}",
              {"assigneeAgentId": agent,
               "comment": "Re-fired a missed wake: assigned with no run, so the assignee was toggled "
                          "through null and back (a same-value write or a comment fires nothing)."},
              f"wake    {issue['identifier']}: reassign")


def stall_hours(issue: dict) -> float:
    return (time.time() - ts(issue["updatedAt"])) / 3600


# --------------------------------------------------------------------------- §2b wedged dispatcher


def wedged(live_runs: list[dict], now: float) -> list[dict]:
    """Agents holding queued runs, running none, the oldest queued past WEDGE_SECONDS.

    Not a missed wake: toggling an assignee only queues another run behind the block.
    The fix is a server restart, which is the operator's, so this only reports.
    """
    by_agent: dict[str, dict] = {}
    for run in live_runs:
        a = by_agent.setdefault(run["agentId"], {"agentId": run["agentId"], "agentName": run.get("agentName"),
                                                 "queued": 0, "running": 0, "oldest": None})
        if run["status"] == "running":
            a["running"] += 1
        elif run["status"] == "queued":
            a["queued"] += 1
            if a["oldest"] is None or run["createdAt"] < a["oldest"]:
                a["oldest"] = run["createdAt"]
    return [a for a in by_agent.values()
            if a["queued"] and not a["running"] and now - ts(a["oldest"]) > WEDGE_SECONDS]


def file_wedges(api, found: list[dict], open_titles: set[str]) -> list[str]:
    filed = []
    for a in found:
        title = f"{WEDGE_TITLE}{a['agentName']} holds {a['queued']} queued run(s), none running"
        if any(t.startswith(f"{WEDGE_TITLE}{a['agentName']} ") for t in open_titles):
            continue
        api.write("POST", f"/companies/{api.company}/issues",
                  {"title": title, "status": "todo", "priority": "high",
                   "description": f"Oldest queued run created {a['oldest']}. The per-agent start lock or an "
                                  "`idle in transaction` backend is holding the queue; a server restart clears "
                                  "it, and a recurrence means the guard bounding it regressed "
                                  "(`AGENT_START_LOCK_MAX_HOLD_MS`, `PAPERCLIP_IDLE_IN_TRANSACTION_TIMEOUT_MS`)."},
                  f"wedge   {a['agentName']}: file for the operator")
        filed.append(a["agentName"])
    return filed


# --------------------------------------------------------------------------- §7 merged branches


def git(project: Path, *args: str, check: bool = True) -> subprocess.CompletedProcess:
    return subprocess.run(["git", "-C", str(project), *args], capture_output=True, text=True,
                          timeout=120, check=check)


def remote_branches(project: Path) -> list[tuple[str, float]]:
    """(branch, tip commit time) for every origin branch except main."""
    out = git(project, "for-each-ref", "--format=%(refname:lstrip=3)\t%(committerdate:unix)",
              "refs/remotes/origin").stdout
    rows = [line.split("\t") for line in out.splitlines() if "\t" in line]
    return [(b, float(t)) for b, t in rows if b not in ("main", "HEAD", "")]


def on_main(project: Path, branch: str, main_tree: str) -> str | None:
    """Why the branch's work is provably on main, or None.

    Case 2 is decided by a merge, not by `git diff main...branch`: that three-dot diff
    compares against the merge base, so a squash-merged branch shows its whole change
    and never reads empty. Merging the branch into main and getting main's tree back
    is the claim the case makes, that the branch adds nothing.
    """
    ref = f"origin/{branch}"
    if git(project, "merge-base", "--is-ancestor", ref, "origin/main", check=False).returncode == 0:
        return "tip is on origin/main"
    merged = git(project, "merge-tree", "--write-tree", "origin/main", ref, check=False)
    if merged.returncode == 0 and merged.stdout.split("\n", 1)[0].strip() == main_tree:
        return "merging it into origin/main changes nothing"
    return None


def deletable(branches: list[tuple[str, float]], open_heads: set[str], now: float) -> list[str]:
    """Branches old enough and with no open PR; whether their work is on main is checked after."""
    return [b for b, at in branches if b not in open_heads and now - at >= BRANCH_MIN_AGE]


def merged_branches(project: Path, open_heads: set[str], dry_run: bool, now: float) -> list[dict]:
    """Remote branches whose work is on main; deleted only under FACILITATOR_DELETE_BRANCHES=1.

    Left to report by default: a deletion on a schedule acts on the shared remote with
    no reader in the loop, so turning it on is the operator's call.
    """
    try:
        git(project, "fetch", "--quiet", "--prune", "origin")
        main_tree = git(project, "rev-parse", "origin/main^{tree}").stdout.strip()
    except subprocess.SubprocessError as exc:
        # Deciding against a stale origin/main could only miss a branch, but say so.
        print(f"branch  sweep skipped: {exc}", flush=True)
        return []
    delete = os.environ.get("FACILITATOR_DELETE_BRANCHES") == "1"
    found = []
    for branch in deletable(remote_branches(project), open_heads, now):
        why = on_main(project, branch, main_tree)
        if not why:
            continue
        deleted = False
        if delete:
            print(("DRY " if dry_run else "") + f"branch  {branch}: delete, {why}", flush=True)
            deleted = dry_run or git(project, "push", "--quiet", "origin", "--delete", branch,
                                     check=False).returncode == 0
        found.append({"branch": branch, "why": why, "deleted": deleted})
    return found


# --------------------------------------------------------------------------- driver


def load(path: Path) -> dict:
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return {}


def save(path: Path, data: dict, dry_run: bool) -> None:
    if dry_run:
        return
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=1))


def sweep(api, project: Path, open_heads: set[str], roster: list[dict], quiet_since=None) -> dict:
    """Run all three checks, act on them, and write REPORT_FILE. Returns the report."""
    now = time.time()
    me = os.environ.get("PAPERCLIP_AGENT_ID")
    paused = {a["id"] for a in roster if a.get("status") in ("paused", "terminated")}
    live_runs = api.get(f"/companies/{api.company}/live-runs") or []

    stalled = missed_wakes(api.issues(status="in_review,in_progress"), live_runs, paused, me, now, quiet_since)
    due, failing, history = plan_toggles(stalled, load(TOGGLES_FILE), now)
    for issue in due:
        toggle(api, issue)
    save(TOGGLES_FILE, history, api.dry_run)

    found = wedged(live_runs, now)
    filed: list[str] = []
    if found:
        open_titles = {i["title"] for i in api.issues(status="backlog,todo,in_progress,in_review,blocked")
                       if i["title"].startswith(WEDGE_TITLE)}
        filed = file_wedges(api, found, open_titles)

    # A merge-tree per remote branch is a minute of the Dispatcher's 600 s budget, and a
    # branch whose work landed costs nothing by waiting, so this runs on its own clock.
    previous = load(REPORT_FILE)
    if now - previous.get("branchesAt", 0) >= BRANCH_SCAN_SECONDS:
        merged, branches_at = merged_branches(project, open_heads, api.dry_run, now), now
    else:
        merged, branches_at = previous.get("branchesOnMain", []), previous["branchesAt"]

    report = {
        "at": now,
        "toggled": [i["identifier"] for i in due],
        "stalledWaiting": [i["identifier"] for i in stalled if i not in due],
        "toggleNotTaking": [{"identifier": i["identifier"], "toggles": history[i["id"]]["count"],
                             "assigneeAgentId": i["assigneeAgentId"]} for i in failing],
        "wedged": found,
        "wedgeFiled": filed,
        "branchesAt": branches_at,
        "branchesOnMain": merged,
    }
    save(REPORT_FILE, report, api.dry_run)
    return report


def main() -> int:
    import argparse
    import importlib.util
    import sys

    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    spec = importlib.util.spec_from_file_location(
        "dispatch", Path(__file__).resolve().parent.parent / "dispatcher" / "dispatch.py")
    dispatch = importlib.util.module_from_spec(spec)
    sys.modules["dispatch"] = dispatch  # its dataclasses resolve their module by name
    spec.loader.exec_module(dispatch)
    project = Path(os.environ["PAPERCLIP_PROJECT"])
    api = dispatch.Api(args.dry_run)
    report = sweep(api, project, set(dispatch.open_pr_heads(project)),
                   api.get(f"/companies/{api.company}/agents"), dispatch.verify_quiet_since(api))
    print(json.dumps(report, indent=1))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
