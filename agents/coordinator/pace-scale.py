#!/usr/bin/env python3
"""Scale the pipeline's supply knobs with how far weekly usage trails the week.

Prints one JSON object:

    {"deficit": 51, "tier": 3, "worker_slots": 12, "reviewer_slots": 12,
     "writer_threshold": 3, "planner_floor": 40, "stock": 12,
     "promote_slots": 12, "why": "..."}

`deficit` is the percentage of the week elapsed minus the percentage of the
weekly limit used. Behind pace, the week's quota is going unused, and three
fixed knobs were what kept it unused: 8 Worker slots, the two-live-writer
contention hold, and the Planner's floor of 20 promotable fronts. With ~40
branches in verify every hot file had two writers, the Coordinator promoted
one task a fire, and Worker slots sat empty at a 50-point deficit.

    --apply   also PATCH the Worker's and Reviewer's
              runtimeConfig.heartbeat.maxConcurrentRuns to the tier's slots.
              The Coordinator's step 5 reads WORKER_SLOTS from the Worker
              agent, so applying here is all it takes for promotion to follow.

Ahead of pace it narrows, progressively down to 2 slots, so the week's quota is
not spent before the reset (an exhausted weekly limit stalls every agent, not
just the Workers). Within 5 points of pace it holds today's fixed values.

FAILS TO BASELINE, never wider. Unreadable usage gives baseline; the 5-hour
session at or above PACE_SCALE_SESSION_CEILING (default 70) caps a widened
tier at baseline and leaves a narrowed one alone. The meter is read through
`cloud-pace.py`'s cache, so this adds no requests to an endpoint that answers
429 when polled hard.

Worker slots stop at 12, not higher. Workers run the pytest guard suites on this
4-core box, so past that, more concurrency only slows every run. The writer
threshold stops at 3: past it, concurrent edits to one file finish later than
sequential ones (see the Coordinator's contention-hold rationale).

STUCK STOCK CAPS NEW WORK, NOT THE WORKER. Stock is work that verified or
escalated but cannot land: `blocked` tasks held by the Architect plus open
`task/*` PRs. Pace alone widens supply straight into that pile, and new work on
a fast-moving `main` turns into more conflicts and more escalations. So stock
narrows only the knobs that admit *new* work -- `promote_slots`, the
contention `writer_threshold` and the Planner's `planner_floor`. At
PACE_SCALE_STOCK_CEILING (default 40) they drop to the floor tier; from
PACE_SCALE_STOCK_BASELINE (default 20) they cap at baseline. At the ceiling
promotion closes outright: `promote_slots` goes to 0, so nothing leaves the
backlog until the pile drains below it. The floor tier still admitted 2
promotions a fire, ~96 a day, more than the pipeline lands. The backlog itself
keeps filling (the Planner's target is `worker_slots`, and `planner_floor`
keeps the floor tier's value): it is a queue, not load, and is ready the
moment promotion reopens. Worker and
Reviewer slots keep the pace tier, because the Coordinator spends Worker slots
on unblock work (conflict rebases) before it promotes anything, and review
drains. The cap never widens, and an unreadable stock caps at baseline.

A VERIFY BLOCKED ONLY ON A RED MAIN IS NOT STOCK. Its Architect recorded a
`<task>.base-red` marker: the task's own diff is clean, and the requeue
re-dispatches it the moment `main` moves. Counted, one compile break on `main`
escalates every verify built on it, and the pile those escalations make closes
promotion for as long as `main` stays red -- the gate punishes the tasks for
`main`'s fault and starves the pipeline on top of the break.
"""

import importlib.util
import json
import os
import subprocess
import sys
import time
import urllib.request
from datetime import datetime

HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location(
    "cloud_pace", os.path.join(HERE, "..", "architect", "cloud-pace.py")
)
cloud_pace = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(cloud_pace)

#: (deficit must exceed, worker slots, reviewer slots, writer threshold, planner floor)
#: A negative deficit is usage *ahead* of the calendar: the week's quota is being
#: spent faster than the week passes, so supply steps down to a floor of 2 slots
#: rather than running the account dry before the reset and stalling every agent.
TIERS = [
    (float("-inf"), 2, 2, 2, 5),
    (-20.0, 4, 4, 2, 10),
    (-10.0, 6, 6, 2, 15),
    (-5.0, 8, 8, 2, 20),
    (0.0, 10, 10, 2, 25),
    (10.0, 12, 12, 3, 30),
    (25.0, 12, 12, 3, 40),
]
#: Today's fixed values, and what an unreadable meter falls back to.
BASELINE = 3

API = os.environ.get("PAPERCLIP_API_URL", "http://127.0.0.1:3100").rstrip("/")
COMPANY = os.environ.get("PAPERCLIP_COMPANY_ID", "cf4422f9-b895-4918-bbe6-985e841e1ffd")


def stock_cap(stock: int | None) -> tuple[int | None, str]:
    """The highest tier stuck stock allows, or None when it allows any."""
    ceiling = cloud_pace.env_float("PACE_SCALE_STOCK_CEILING", 40)
    baseline = cloud_pace.env_float("PACE_SCALE_STOCK_BASELINE", 20)
    if stock is None:
        return BASELINE, "stock unreadable: capped at baseline"
    if stock >= ceiling:
        return 0, f"stock {stock} at or over {ceiling:.0f}: promotion closed"
    if stock >= baseline:
        return BASELINE, f"stock {stock} at or over {baseline:.0f}: supply capped at baseline"
    return None, f"stock {stock}"


def cap_supply(result: dict, stock: int | None) -> dict:
    cap, why = stock_cap(stock)
    result["stock"] = stock
    result["promote_slots"] = result["worker_slots"]
    result["why"] = f"{result['why']}; {why}"
    if cap is not None and cap < result["tier"]:
        _, workers, _, writers, floor = TIERS[cap]
        result.update(promote_slots=workers, writer_threshold=writers, planner_floor=floor)
    if cap == 0:
        result["promote_slots"] = 0  # promotion closed: unblock and land only
    return result


def base_red_escalations(verify_dir: str) -> set[str]:
    """Identifiers of the tasks that escalated on a base-red marker."""
    out = set()
    try:
        names = os.listdir(verify_dir)
    except OSError:
        return out
    for name in names:
        if not name.endswith(".base-red"):
            continue
        try:
            with open(os.path.join(verify_dir, name)) as fh:
                lines = fh.read().splitlines()
        except OSError:
            continue
        out.add(lines[1].strip() if len(lines) > 1 and lines[1].strip() else name[: -len(".base-red")])
    return out


def read_stock() -> int | None:
    """Architect-held `blocked` tasks plus open `task/*` PRs, less verifies blocked on a red `main`."""
    with urllib.request.urlopen(f"{API}/api/companies/{COMPANY}/agents", timeout=10) as resp:
        agents = {a["name"]: a["id"] for a in json.load(resp)}
    url = f"{API}/api/companies/{COMPANY}/issues?status=blocked&assigneeAgentId={agents['Architect']}"
    with urllib.request.urlopen(url, timeout=30) as resp:
        verify_dir = os.path.join(os.environ.get("XDG_CACHE_HOME") or os.path.expanduser("~/.cache"), "paperclip-verify")
        base_red = base_red_escalations(verify_dir)
        blocked = sum(1 for i in json.load(resp) if i["status"] == "blocked" and i["identifier"] not in base_red)
    prs = subprocess.run(
        ["gh", "pr", "list", "--state", "open", "--limit", "500", "--json", "headRefName",
         "--jq", '[.[] | select(.headRefName | startswith("task/"))] | length'],
        cwd=os.environ["PAPERCLIP_PROJECT"], capture_output=True, text=True, timeout=60, check=True,
    )
    return blocked + int(prs.stdout)


def scale(usage: dict | None, now: float) -> dict:
    ceiling = cloud_pace.env_float("PACE_SCALE_SESSION_CEILING", 70)
    if usage is None:
        return _tier(BASELINE, None, "usage unreadable: baseline")
    week = usage["seven_day"]
    used = float(week["utilization"])
    reset = datetime.fromisoformat(week["resets_at"]).timestamp()
    elapsed = min(100.0, max(0.0, 100 * (1 - (reset - now) / cloud_pace.WEEK)))
    session = float((usage.get("five_hour") or {}).get("utilization") or 0)
    deficit = elapsed - used
    why = f"week {used:.0f}% used, {elapsed:.0f}% elapsed, session {session:.0f}%"
    tier = max(i for i, t in enumerate(TIERS) if deficit > t[0])
    if session >= ceiling and tier > BASELINE:
        # A hot 5-hour window caps supply at baseline; it never widens a tier
        # that pace has already narrowed.
        return _tier(BASELINE, deficit, f"{why}: session at or over {ceiling:.0f}%: capped at baseline")
    return _tier(tier, deficit, f"{why}: deficit {deficit:.0f} points")


def _tier(i: int, deficit: float | None, why: str) -> dict:
    _, workers, reviewers, writers, floor = TIERS[i]
    return {
        "deficit": None if deficit is None else round(deficit),
        "tier": i,
        "worker_slots": workers,
        "reviewer_slots": reviewers,
        "writer_threshold": writers,
        "planner_floor": floor,
        "why": why,
    }


def apply(result: dict) -> list[str]:
    def call(method: str, path: str, body: dict | None = None):
        req = urllib.request.Request(
            f"{API}/api{path}",
            data=None if body is None else json.dumps(body).encode(),
            method=method,
            headers={"Content-Type": "application/json"},
        )
        with urllib.request.urlopen(req, timeout=10) as resp:
            return json.load(resp)

    changed = []
    agents = {a["name"]: a for a in call("GET", f"/companies/{COMPANY}/agents")}
    for name, slots in (("Worker", result["worker_slots"]), ("Reviewer", result["reviewer_slots"])):
        agent = agents.get(name)
        if agent is None:
            continue
        config = agent.get("runtimeConfig") or {}
        heartbeat = config.setdefault("heartbeat", {})
        if heartbeat.get("maxConcurrentRuns") == slots:
            continue
        before = heartbeat.get("maxConcurrentRuns")
        heartbeat["maxConcurrentRuns"] = slots
        call("PATCH", f"/agents/{agent['id']}", {"runtimeConfig": config})
        changed.append(f"{name} maxConcurrentRuns {before} -> {slots}")
    return changed


def main() -> int:
    now = cloud_pace.env_float("CLOUD_PACE_NOW", time.time())
    try:
        usage = cloud_pace.read_usage()
    except Exception:
        usage = None
    try:
        result = scale(usage, now)
    except Exception as exc:  # a changed meter shape degrades to baseline
        result = _tier(BASELINE, None, f"usage unparseable ({type(exc).__name__}): baseline")
    try:
        stock = read_stock()
    except Exception:
        stock = None
    result = cap_supply(result, stock)
    if "--apply" in sys.argv[1:]:
        try:
            result["applied"] = apply(result)
        except Exception as exc:
            result["applied"] = [f"apply failed: {type(exc).__name__}: {exc}"]
    print(json.dumps(result))
    return 0


if __name__ == "__main__":
    sys.exit(main())
