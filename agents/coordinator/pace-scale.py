#!/usr/bin/env python3
"""Set the pipeline's supply knobs from the one quota gate, `cloud-pace.py`.

Prints one JSON object:

    {"open": true, "worker_slots": 12, "reviewer_slots": 10,
     "writer_threshold": 2, "planner_floor": 40, "promote_slots": 12,
     "why": "..."}

    --apply   also PATCH the Worker's and Reviewer's
              runtimeConfig.heartbeat.maxConcurrentRuns to the slots.
              The Coordinator's step 5 reads WORKER_SLOTS from the Worker
              agent, so applying here is all it takes for promotion to follow.

GATE OPEN: full width. Worker slots, promotion and the Planner's floor sit at
their maximum.
GATE CLOSED: promotion stops (`promote_slots` 0) and the Planner's floor drops
to 0, so no new work starts and the quota left under the ceiling goes to
landing what is already in flight. Worker slots stay full, because the
Coordinator spends them on unblock work (conflict rebases) before it promotes
anything, and that work is landing, not new supply.

NO SECOND THROTTLE. This script used to narrow supply on its own reading of the
meter -- tiers by how far usage ran ahead of the calendar, a cap on a hot
5-hour session -- and to close promotion at 40 open PRs plus Architect-held
tasks. Each disagreed with the cloud lane: at 91% of the week the lane was open
and the Architect launched cloud verifies, while this script had narrowed the
Planner's floor to 5 and the stock count had closed promotion, so Workers sat
idle for hours. The stock count also counted open PRs, which ties supply to the
operator's merge cadence -- the dependency the contention hold already refuses
(a branch whose PR is open holds nothing). Conflicts from unmerged work are the
rebase lane's, and their cost is quota, which the gate already bounds. Do not
re-add a usage, session or stock threshold here; change `cloud-pace.py`'s
ceiling instead.

Worker slots stop at 12. Workers run the pytest guard suites on this 4-core
box, so past that, more concurrency only slows every run. The writer threshold
is the contention hold's own two writers, not a quota knob: past two, concurrent
edits to one file finish later than sequential ones (see the Coordinator's
contention-hold rationale). Reviewer slots sit at
the server's ceiling: a Reviewer runs no cargo and no pytest, and review only
drains work a Worker already produced.
"""

import importlib.util
import json
import os
import sys
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location(
    "cloud_pace", os.path.join(HERE, "..", "architect", "cloud-pace.py")
)
cloud_pace = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(cloud_pace)

WORKER_SLOTS = 12
REVIEWER_SLOTS = 10
WRITER_THRESHOLD = 2
PLANNER_FLOOR = 40

API = os.environ.get("PAPERCLIP_API_URL", "http://127.0.0.1:3100").rstrip("/")
COMPANY = os.environ.get("PAPERCLIP_COMPANY_ID", "cf4422f9-b895-4918-bbe6-985e841e1ffd")


def knobs(open_: bool, why: str) -> dict:
    return {
        "open": open_,
        "worker_slots": WORKER_SLOTS,
        "reviewer_slots": REVIEWER_SLOTS,
        "writer_threshold": WRITER_THRESHOLD,
        "planner_floor": PLANNER_FLOOR if open_ else 0,
        "promote_slots": WORKER_SLOTS if open_ else 0,
        "why": why if open_ else f"{why}: promotion closed",
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
    result = knobs(*cloud_pace.is_open_now())
    if "--apply" in sys.argv[1:]:
        try:
            result["applied"] = apply(result)
        except Exception as exc:
            result["applied"] = [f"apply failed: {type(exc).__name__}: {exc}"]
    print(json.dumps(result))
    return 0


if __name__ == "__main__":
    sys.exit(main())
