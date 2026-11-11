"""The Facilitator's rule-shaped checks, run on the Dispatcher's sweep instead of nightly.

Four of the Facilitator's steps need no judgment: re-firing a missed wake (§2a),
spotting a wedged per-agent dispatcher (§2b), finding remote branches whose work is
already on `origin/main` (§7 cases 1-2), and pushing local task branches whose
commits exist nowhere else (§7b). As a nightly model run they failed
on the same thing that causes the stalls they exist to clear. Wakes die when the
account's usage limit runs out, and so did the Facilitator, two nights running, while
verify stages sat idle for days with nothing left to re-fire them. A script spends no
model quota and runs every half hour, so a stall lasts one sweep, not a day.

Three more are readings the nightly run could not take for itself. A routine's own
firing is hidden from the default issue list, so a firing whose wake died was never
re-fired by anyone (`missed_routines`). And two things were only ever sampled: the last
day of runs, which the nightly run read fifty rows at a time (`run_digest`), and whether
main's nightly check is passing or has stopped arriving (`read_nightly`).

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
PENDING_FILE = STATE_DIR / "facilitator-pending-toggles.json"

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
#: A local task branch untouched this long, with commits main lacks and no origin copy,
#: is pushed. Matches the project guard's GRACE_DAYS (check_unpushed_task_branches.py):
#: younger branches are the normal mid-flight queue, which only the Architect pushes.
STRANDED_AGE = float(os.environ.get("FACILITATOR_STRANDED_AGE_SECONDS", 14 * 24 * 3600))
STRANDED_GLOB = "refs/heads/task/AA-*"
#: reap.py's cadence. It runs detached: its first pass over a long backlog takes
#: longer than the Dispatcher's run is allowed to.
REAP_SCAN_SECONDS = float(os.environ.get("FACILITATOR_REAP_SCAN_SECONDS", 6 * 3600))
REAP_LOG = STATE_DIR / "reap.log"
REAP_PID = STATE_DIR / "reap.pid"
#: The issue list leaves these out unless asked, so every scan built on it is blind to
#: a routine's own task.
ROUTINE_ORIGIN = "routine_execution"
UNRUN_STATUSES = ("todo", "in_progress")
PARKED_STATUSES = ("in_review", "blocked")
#: A parked firing with no run for this long is replaced by a later firing. Two days,
#: so a daily routine's held firing outlives the next one and is still there to answer.
PARKED_SECONDS = float(os.environ.get("FACILITATOR_PARKED_SECONDS", 48 * 3600))
#: How far back `run_digest` counts, and the most rows it reads to get there.
DIGEST_SECONDS = float(os.environ.get("FACILITATOR_DIGEST_SECONDS", 24 * 3600))
DIGEST_ROWS = int(os.environ.get("FACILITATOR_DIGEST_ROWS", 1000))
QUOTA_ERROR = "claude_usage_limit"
#: The commit status the nightly check posts on main, and how old the newest one may
#: be before its absence is the finding: a day's cadence plus half a day of slack.
NIGHTLY_CONTEXT = os.environ.get("FACILITATOR_NIGHTLY_CONTEXT", "tester/nightly")
NIGHTLY_STALE_SECONDS = float(os.environ.get("FACILITATOR_NIGHTLY_STALE_SECONDS", 36 * 3600))
NIGHTLY_PAGES = 3
WEDGE_TITLE = "[class:wedged-dispatcher] "
STAGE_PREFIXES = ("Review:", "Verify:", "ci-fix:", "Rebase ")
STAGE_KEYS = {"review", "verify", "ci-fix", "rebase"}


def ts(stamp: str) -> float:
    return datetime.fromisoformat(stamp.replace("Z", "+00:00")).timestamp()


def is_stage(issue: dict) -> bool:
    return (issue.get("dedupeKey") or "") in STAGE_KEYS or issue["title"].startswith(STAGE_PREFIXES)


# --------------------------------------------------------------------------- §2a missed wakes


def missed_wakes(issues: list[dict], live_runs: list[dict], paused: set[str], skip_agent: str | None,
                 now: float, quiet_since=None, parent_closed=None,
                 parent_owed: frozenset[str] = frozenset()) -> list[dict]:
    """Assigned tasks whose wake never started a run, oldest stall first.

    A Worker parent `in_review` with no run is waiting on its stage children, which is
    healthy; only a stage, or a task its agent had already taken `in_progress`, is owed
    a run. The Dispatcher's own Verifies wait on a cloud build with no run by design.

    `parent_owed` names agents that hold a parent `in_review` only to act on it
    themselves — the Architect, handed a parent with no `Verify:` stage to open its
    PR. Such a parent has no children to wait on, so it is owed a run like a stage.
    Leaving it out stranded one for about 23h, twice: the Architect bound its cloud
    verdict's wake to the stage-less parent, the verdict came back PASS, and nothing
    re-fired it.

    `quiet_since(issue)` is when the task last did anything off the board, or None
    while work it is waiting on is still running: a Verify has no run for the hours
    its build is out, and that is not a stall. It defaults to `updatedAt`.

    `parent_closed(issue)` says whether a stage's parent is `done`/`cancelled`. Such a
    stage has nothing left to do (its worktree is reaped), so every toggle would buy
    a run that aborts.
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
        if issue["status"] == "in_review" and not is_stage(issue) and agent not in parent_owed:
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
        if parent_closed and is_stage(issue) and parent_closed(issue):
            continue
        out.append(issue)
    return sorted(out, key=lambda i: i["updatedAt"])


def closed_parent_check(api, open_issues: list[dict]):
    """`parent_closed` for missed_wakes: a parent listed as open is not closed; others are read."""
    open_ids = {i["id"] for i in open_issues}

    def parent_closed(issue: dict) -> bool:
        parent = issue.get("parentId")
        if not parent or parent in open_ids:
            return False
        return (api.get(f"/issues/{parent}") or {}).get("status") in ("done", "cancelled")
    return parent_closed


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


def finish_toggles(api, pending: dict) -> list[str]:
    """Reassign every task a toggle unassigned and never gave back.

    A toggle is two writes, and the sweep can die between them: it runs under a time
    budget on a box that is sometimes saturated, and a write that times out is never
    retried. The task is then open with no assignee, which no scan here or anywhere
    else reads as owed anything. Two were left that way in one evening, a Verify and a
    routine's own firing. So the agent is journalled before the unassign, and whatever
    the journal still holds at the next sweep is given back first.

    An entry is dropped once the task has an assignee again, or is closed, whoever did
    that. A read or write that fails leaves the journal alone for the next sweep.
    """
    finished = []
    for issue_id, entry in list(pending.items()):
        issue = api.get(f"/issues/{issue_id}") or {}
        open_ = issue.get("status") not in (None, "done", "cancelled")
        if open_ and not issue.get("assigneeAgentId") and not issue.get("assigneeUserId"):
            api.write("PATCH", f"/issues/{issue_id}",
                      {"assigneeAgentId": entry["agent"],
                       "comment": "Reassigned: a missed-wake toggle unassigned this task and the sweep ended "
                                  "before giving it back."},
                      f"wake    {entry['identifier']}: finish an interrupted toggle")
            finished.append(entry["identifier"])
        del pending[issue_id]
    return finished


def stall_hours(issue: dict) -> float:
    return (time.time() - ts(issue["updatedAt"])) / 3600


# --------------------------------------------------------------------------- §2a routine firings


def missed_routines(issues: list[dict], live_runs: list[dict], paused: set[str], skip_agent: str | None,
                    now: float, last_fired: dict[str, dict] | None = None) -> tuple[list[dict], list[tuple[dict, str]]]:
    """(firings owed a wake, [(firing a later one replaces, what replaces it)]).

    `issues` are a company's open routine firings. A routine files one task per firing
    and wakes its agent once; when that wake dies (the usage limit was out), the task
    sits assigned with no run, and the schedule's next firing files another beside it
    instead of retrying. Two daily routines went three days without one completed run
    that way, one of them the nightly check on main.

    Only a routine's newest firing is worth a run: an older one asks for the same sweep
    over a staler tree. So the newest is re-fired if it has stalled, and every stalled
    firing behind it is superseded, whether or not the newest is itself running.

    "Behind it" is read two ways, because a later firing that finished is no longer in
    `issues`. A newer open firing of the same routine is one. The other is
    `last_fired[routine]`, the routine's last run as `{"at", "issueId"}`: a run that
    filed a different task after this one was created. A run with no task of its own
    (skipped, or coalesced into this firing) replaces nothing, so the firing it left
    alone is still the newest and is still re-fired.

    A firing parked `in_review` or `blocked` is never re-fired, since someone put it
    there, and it gets PARKED_SECONDS rather than STALL_SECONDS before a later firing
    replaces it. One sat `in_review` for a month and another `blocked` for three weeks,
    each with twenty later firings of its routine completed after it.

    `skip_agent` is the agent running this sweep. Its own firings are never re-fired
    (this run is the newest one), but the ones a killed or timed-out sweep left
    behind are superseded like anyone's.
    """
    live_ids = {r["id"] for r in live_runs}
    live_issues = {r.get("issueId") for r in live_runs if r.get("issueId")}

    def idle(issue: dict) -> float | None:
        """Seconds since the firing last moved, or None while a run is on it."""
        if issue.get("activeRun") or issue["id"] in live_issues:
            return None
        if issue.get("executionRunId") and issue["executionRunId"] in live_ids:
            return None
        return now - ts(issue["updatedAt"])

    by_routine: dict[str, list[dict]] = {}
    for issue in issues:
        agent = issue.get("assigneeAgentId")
        if issue.get("originKind") != ROUTINE_ORIGIN or not issue.get("originId"):
            continue
        if not agent or agent in paused:
            continue
        if issue["status"] not in UNRUN_STATUSES + PARKED_STATUSES:
            continue
        by_routine.setdefault(issue["originId"], []).append(issue)

    refire, superseded = [], []
    for routine, firings in by_routine.items():
        firings.sort(key=lambda i: i["createdAt"])
        newest = firings[-1]
        fired = (last_fired or {}).get(routine) or {}
        for issue in firings:
            parked = issue["status"] in PARKED_STATUSES
            quiet = idle(issue)
            if quiet is None or quiet < (PARKED_SECONDS if parked else STALL_SECONDS):
                continue
            if issue is not newest:
                superseded.append((issue, newest["identifier"]))
            elif (fired.get("issueId") and fired["issueId"] != issue["id"]
                  and fired.get("at", 0) > ts(issue["createdAt"])):
                superseded.append((issue, "a later firing that has since closed"))
            elif not parked and issue["assigneeAgentId"] != skip_agent:
                refire.append(issue)
    return sorted(refire, key=lambda i: i["updatedAt"]), superseded


def routine_last_fired(routines: list[dict]) -> dict[str, dict]:
    """`last_fired` for missed_routines, from the company's routine list."""
    out = {}
    for routine in routines:
        run = routine.get("lastRun") or {}
        if run.get("triggeredAt"):
            out[routine["id"]] = {"at": ts(run["triggeredAt"]), "issueId": run.get("linkedIssueId")}
    return out


def supersede(api, old: dict, by: str) -> None:
    api.set_status(old, {"status": "cancelled"},
                   f"Superseded by {by}: this firing has had no run for {stall_hours(old):.0f}h and the routine "
                   "has fired again since. Only a routine's newest firing is worth a run.",
                   f"routine {old['identifier']}: superseded by {by}")


# --------------------------------------------------------------------------- §3 run digest


def run_digest(runs: list[dict], names: dict[str, str], now: float) -> dict:
    """The last DIGEST_SECONDS of runs, counted per agent by outcome.

    `quotaOut` names the agents whose newest finished run died on the usage limit: for
    those, every failure in the window is one cause, not a config bug per run.
    `coveredHours` is how far back the rows actually reached. A flood of failed wakes
    can fill the fetch in a few hours, and a count that silently covers less than the
    window reads as a quiet day.
    """
    def at(run: dict) -> float:
        return ts(run.get("startedAt") or run["createdAt"])

    counts: dict[str, dict[str, int]] = {}
    newest_finished: dict[str, dict] = {}
    oldest = now
    for run in runs:
        when = at(run)
        oldest = min(oldest, when)
        if now - when > DIGEST_SECONDS:
            continue
        agent = names.get(run["agentId"], run["agentId"])
        outcome = run["status"] + (f":{run['errorCode']}" if run.get("errorCode") else "")
        counts.setdefault(agent, {})
        counts[agent][outcome] = counts[agent].get(outcome, 0) + 1
        if run.get("finishedAt") and (agent not in newest_finished or when > at(newest_finished[agent])):
            newest_finished[agent] = run
    return {
        "coveredHours": round(min(now - oldest, DIGEST_SECONDS) / 3600, 1),
        "byAgent": counts,
        "quotaOut": sorted(a for a, r in newest_finished.items() if r.get("errorCode") == QUOTA_ERROR),
    }


# --------------------------------------------------------------------------- main's nightly check


def read_nightly(commits: list[dict], now: float) -> dict:
    """The newest NIGHTLY_CONTEXT status among main's commits, newest commit first.

    `stale` covers both ways the check can stop speaking for main: the newest status
    is older than NIGHTLY_STALE_SECONDS, or the commits searched reach back past that
    age and carry none. A search that ran out of commits before reaching that age
    proves nothing either way and says so with `stale: None`.
    """
    for behind, commit in enumerate(commits):
        for status in (commit.get("status") or {}).get("contexts") or []:
            if status["context"] == NIGHTLY_CONTEXT:
                age = now - ts(status["createdAt"])
                return {"sha": commit["oid"], "state": status["state"].lower(), "ageHours": round(age / 3600, 1),
                        "commitsSince": behind, "stale": age > NIGHTLY_STALE_SECONDS}
    reached = now - ts(commits[-1]["committedDate"]) if commits else 0
    return {"sha": None, "state": None, "searched": len(commits),
            "stale": True if reached > NIGHTLY_STALE_SECONDS else None}


NIGHTLY_QUERY = """query($owner:String!,$name:String!,$after:String){repository(owner:$owner,name:$name){
ref(qualifiedName:"refs/heads/main"){target{... on Commit{history(first:100,after:$after){
pageInfo{hasNextPage endCursor}
nodes{oid committedDate status{contexts{context state createdAt}}}}}}}}}"""


def nightly(project: Path, now: float) -> dict:
    """`read_nightly` over main's recent commits. A failed read is reported, not raised:
    the rest of the sweep does not depend on it."""
    commits: list[dict] = []
    after = None
    try:
        for _ in range(NIGHTLY_PAGES):
            args = ["gh", "api", "graphql", "-F", "owner={owner}", "-F", "name={repo}", "-f", f"query={NIGHTLY_QUERY}"]
            if after:
                args += ["-f", f"after={after}"]
            out = subprocess.run(args, cwd=project, capture_output=True, text=True, timeout=60, check=True).stdout
            history = json.loads(out)["data"]["repository"]["ref"]["target"]["history"]
            commits += history["nodes"]
            found = read_nightly(commits, now)
            if found["sha"] or not history["pageInfo"]["hasNextPage"]:
                return found
            after = history["pageInfo"]["endCursor"]
        return read_nightly(commits, now)
    except (subprocess.SubprocessError, OSError, KeyError, TypeError, ValueError) as exc:
        return {"error": f"{type(exc).__name__}: {exc}"[:300]}


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


def file_wedges(api, found: list[dict], filed_before: list[dict]) -> list[str]:
    """One class-keyed operator filing per agent (INSTRUCTIONS §Filing): an open one is
    left alone, a closed one is reopened as a recurrence, otherwise a new one is filed."""
    held = ("Held: operator — a server restart clears the wedged queue; a recurrence means "
            "the guard bounding it regressed.")
    filed = []
    for a in found:
        prefix = f"{WEDGE_TITLE}{a['agentName']} "
        mine = sorted((i for i in filed_before if i["title"].startswith(prefix)), key=lambda i: i["createdAt"])
        if any(i["status"] not in ("done", "cancelled") for i in mine):
            continue
        occurrence = f"Oldest queued run created {a['oldest']}; {a['queued']} queued, none running."
        if mine:
            api.set_status(mine[-1], {"status": "blocked"},
                           f"{held}\n\nRecurrence: {occurrence} The closure before this one cleared the "
                           "queue, not the mechanism.",
                           f"wedge   {a['agentName']}: reopen {mine[-1]['identifier']} as a recurrence")
        else:
            created = api.write(
                "POST", f"/companies/{api.company}/issues",
                {"title": f"{prefix}holds queued runs, none running", "status": "blocked", "priority": "high",
                 "description": "The per-agent start lock or an `idle in transaction` backend is holding the "
                                "queue. Guards that should bound it: `AGENT_START_LOCK_MAX_HOLD_MS`, "
                                "`PAPERCLIP_IDLE_IN_TRANSACTION_TIMEOUT_MS`."},
                f"wedge   {a['agentName']}: file for the operator")
            if created:
                api.write("POST", f"/issues/{created['id']}/comments", {"body": f"{held}\n\n{occurrence}"},
                          f"wedge   {a['agentName']}: hold")
        filed.append(a["agentName"])
    return filed


# --------------------------------------------------------------------------- §7 merged branches


def git(project: Path, *args: str, check: bool = True) -> subprocess.CompletedProcess:
    return subprocess.run(["git", "-C", str(project), *args], capture_output=True, text=True,
                          timeout=120, check=check)


def remote_branches(project: Path) -> list[tuple[str, float, str]]:
    """(branch, tip commit time, tip sha) for every origin branch except main."""
    out = git(project, "for-each-ref", "--format=%(refname:lstrip=3)\t%(committerdate:unix)\t%(objectname)",
              "refs/remotes/origin").stdout
    rows = [line.split("\t") for line in out.splitlines() if line.count("\t") == 2]
    return [(b, float(t), sha) for b, t, sha in rows if b not in ("main", "HEAD", "")]


def on_main(project: Path, tip: str, main: str) -> str | None:
    """Why the branch's work is provably on main, or None.

    Case 2 is decided by a merge, not by `git diff main...branch`: that three-dot diff
    compares against the merge base, so a squash-merged branch shows its whole change
    and never reads empty. Merging the branch into main and getting main's tree back
    is the claim the case makes, that the branch adds nothing.

    Both sides are commits, not refs: other sweeps fetch into the same repo, and a ref
    that moves mid-scan would compare one branch against two different mains.
    """
    if git(project, "merge-base", "--is-ancestor", tip, main, check=False).returncode == 0:
        return "tip is on origin/main"
    main_tree = git(project, "rev-parse", f"{main}^{{tree}}").stdout.strip()
    merged = git(project, "merge-tree", "--write-tree", main, tip, check=False)
    if merged.returncode == 0 and merged.stdout.split("\n", 1)[0].strip() == main_tree:
        return "merging it into origin/main changes nothing"
    return None


def deletable(branches: list[tuple[str, float, str]], open_heads: set[str], now: float) -> list[tuple[str, str]]:
    """(branch, tip) old enough and with no open PR; whether the work is on main is checked after."""
    return [(b, sha) for b, at, sha in branches if b not in open_heads and now - at >= BRANCH_MIN_AGE]


def merged_branches(project: Path, open_heads: set[str], dry_run: bool, now: float) -> list[dict]:
    """Remote branches whose work is on main; deleted only under FACILITATOR_DELETE_BRANCHES=1.

    Left to report by default: a deletion on a schedule acts on the shared remote with
    no reader in the loop, so turning it on is the operator's call.
    """
    try:
        git(project, "fetch", "--quiet", "--prune", "origin")
        main = git(project, "rev-parse", "origin/main").stdout.strip()
    except subprocess.SubprocessError as exc:
        # Deciding against a stale origin/main could only miss a branch, but say so.
        print(f"branch  sweep skipped: {exc}", flush=True)
        return []
    delete = os.environ.get("FACILITATOR_DELETE_BRANCHES") == "1"
    found = []
    for branch, tip in deletable(remote_branches(project), open_heads, now):
        why = on_main(project, tip, main)
        if not why:
            continue
        deleted = False
        if delete:
            print(("DRY " if dry_run else "") + f"branch  {branch}: delete, {why}", flush=True)
            # The lease refuses the delete if the branch moved since it was checked.
            deleted = dry_run or git(project, "push", "--quiet", f"--force-with-lease={branch}:{tip}",
                                     "origin", f":refs/heads/{branch}", check=False).returncode == 0
        found.append({"branch": branch, "why": why, "deleted": deleted})
    return found


# --------------------------------------------------------------------------- §7b stranded local branches


def stranded_branches(project: Path, dry_run: bool, now: float) -> list[dict]:
    """Push every local task branch whose commits exist only on this disk.

    Pushing is the remedy the project guard names, and the only non-destructive one:
    the commits gain a second copy and nothing is rewritten, so unlike §7's deletion it
    needs no opt-in. `--no-verify` because the pre-push hook is a landing gate, and this
    push lands nothing; it only stops the work existing on one disk.

    Run after merged_branches' fetch, so `origin/<branch>` and `origin/main` are current.
    """
    out = git(project, "for-each-ref", "--format=%(refname:short)\t%(committerdate:unix)",
              STRANDED_GLOB, check=False).stdout
    found = []
    for line in out.splitlines():
        branch, _, at = line.partition("\t")
        if not at or now - float(at) < STRANDED_AGE:
            continue
        if git(project, "rev-parse", "--verify", "-q", f"refs/remotes/origin/{branch}",
               check=False).returncode == 0:
            continue
        # `git cherry`, so a branch whose patches landed under other SHAs is not work.
        ahead = git(project, "cherry", "origin/main", branch, check=False).stdout.count("+ ")
        if not ahead:
            continue
        print(("DRY " if dry_run else "") + f"branch  {branch}: push, {ahead} commit(s) only here", flush=True)
        pushed = dry_run or git(project, "push", "--quiet", "--no-verify", "origin", branch,
                                check=False).returncode == 0
        found.append({"branch": branch, "ahead": ahead, "pushed": pushed})
    return found


# --------------------------------------------------------------------------- reap


def reap_running() -> bool:
    try:
        os.kill(int(REAP_PID.read_text()), 0)
        return True
    except (OSError, ValueError):
        return False


def launch_reap(dry_run: bool) -> bool:
    """Start reap.py detached, unless one is still running. It acts only under REAP_ACT=1.

    Off by default for the same reason §7's deletion is: it acts on the shared remote
    and the cloud account with no reader in the loop, so turning it on is the
    operator's call. Without it, reap.log is the report of what it would do.
    """
    if dry_run or reap_running():
        return False
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    args = ["python3", str(Path(__file__).with_name("reap.py"))]
    if os.environ.get("REAP_ACT") == "1":
        args.append("--act")
    with open(REAP_LOG, "w") as log:
        proc = subprocess.Popen(args, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
    REAP_PID.write_text(str(proc.pid))
    return True


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
    """Run every check, act on them, and write REPORT_FILE. Returns the report."""
    now = time.time()
    me = os.environ.get("PAPERCLIP_AGENT_ID")
    paused = {a["id"] for a in roster if a.get("status") in ("paused", "terminated")}
    live_runs = api.get(f"/companies/{api.company}/live-runs") or []

    pending = load(PENDING_FILE)
    finished = finish_toggles(api, pending)
    save(PENDING_FILE, pending, api.dry_run)

    open_issues = api.issues(status="in_review,in_progress")
    # By name: the roster is the only place the Architect's id lives.
    parent_owed = frozenset(a["id"] for a in roster if a.get("name") == "Architect")
    stalled = missed_wakes(open_issues, live_runs, paused, me, now, quiet_since,
                           closed_parent_check(api, open_issues), parent_owed)
    routine_firings = api.issues(status=",".join(UNRUN_STATUSES + PARKED_STATUSES), includeRoutineExecutions="true")
    last_fired = routine_last_fired(api.get(f"/companies/{api.company}/routines") or [])
    refire, superseded = missed_routines(routine_firings, live_runs, paused, me, now, last_fired)
    for old, by in superseded:
        supersede(api, old, by)
    # Routine firings go first: there are a handful at most, and TOGGLE_CAP would
    # otherwise leave a day-old health sweep behind twenty older stages.
    stalled = refire + stalled
    due, failing, history = plan_toggles(stalled, load(TOGGLES_FILE), now)
    for issue in due:
        pending[issue["id"]] = {"agent": issue["assigneeAgentId"], "identifier": issue["identifier"]}
        save(PENDING_FILE, pending, api.dry_run)
        toggle(api, issue)
        del pending[issue["id"]]
    save(PENDING_FILE, pending, api.dry_run)
    save(TOGGLES_FILE, history, api.dry_run)

    found = wedged(live_runs, now)
    filed: list[str] = []
    if found:
        filed_before = [i for i in api.issues(status="backlog,todo,in_progress,in_review,blocked,done,cancelled")
                        if i["title"].startswith(WEDGE_TITLE)]
        filed = file_wedges(api, found, filed_before)

    # A merge-tree per remote branch is a minute of the Dispatcher's 600 s budget, and a
    # branch whose work landed costs nothing by waiting, so this runs on its own clock.
    previous = load(REPORT_FILE)
    if now - previous.get("branchesAt", 0) >= BRANCH_SCAN_SECONDS:
        merged, branches_at = merged_branches(project, open_heads, api.dry_run, now), now
        stranded = stranded_branches(project, api.dry_run, now)
        main_nightly = nightly(project, now)
    else:
        merged, branches_at = previous.get("branchesOnMain", []), previous["branchesAt"]
        stranded = previous.get("strandedPushed", [])
        main_nightly = previous.get("nightly") or nightly(project, now)

    names = {a["id"]: a["name"] for a in roster}
    digest = run_digest(api.get(f"/companies/{api.company}/heartbeat-runs?limit={DIGEST_ROWS}") or [], names, now)

    reap_at = previous.get("reapAt", 0)
    if now - reap_at >= REAP_SCAN_SECONDS and launch_reap(api.dry_run):
        reap_at = now

    report = {
        "at": now,
        "toggled": [i["identifier"] for i in due],
        "togglesFinished": finished,
        "stalledWaiting": [i["identifier"] for i in stalled if i not in due],
        "toggleNotTaking": [{"identifier": i["identifier"], "toggles": history[i["id"]]["count"],
                             "assigneeAgentId": i["assigneeAgentId"]} for i in failing],
        "routinesRefired": [i["identifier"] for i in due if i in refire],
        "routinesSuperseded": [{"identifier": old["identifier"], "by": by} for old, by in superseded],
        "runDigest": digest,
        "nightly": main_nightly,
        "wedged": found,
        "wedgeFiled": filed,
        "branchesAt": branches_at,
        "branchesOnMain": merged,
        "strandedPushed": stranded,
        "reapAt": reap_at,
        "reapLog": str(REAP_LOG),
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
