#!/usr/bin/env python3
"""Scale the pipeline's supply knobs with how far weekly usage trails the week.

Prints one JSON object:

    {"deficit": 51, "tier": 3, "worker_slots": 12, "reviewer_slots": 12,
     "writer_threshold": 3, "planner_floor": 40, "why": "..."}

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

FAILS TO BASELINE, never wider. Unreadable usage, the 5-hour session at or
above PACE_SCALE_SESSION_CEILING (default 70), or usage on or ahead of the
week all give tier 0, today's fixed values. The meter is read through
`cloud-pace.py`'s cache, so this adds no requests to an endpoint that answers
429 when polled hard.

Worker slots stop at 12, not higher. Workers run the pytest guard suites on this
4-core box, so past that, more concurrency only slows every run. The writer
threshold stops at 3: past it, concurrent edits to one file finish later than
sequential ones (see the Coordinator's contention-hold rationale).
"""

import importlib.util
import json
import os
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

#: (minimum deficit in points, worker slots, reviewer slots, writer threshold, planner floor)
TIERS = [
    (float("-inf"), 8, 8, 2, 20),
    (0.0, 10, 10, 2, 25),
    (10.0, 12, 12, 3, 30),
    (25.0, 12, 12, 3, 40),
]

API = os.environ.get("PAPERCLIP_API_URL", "http://127.0.0.1:3100").rstrip("/")
COMPANY = os.environ.get("PAPERCLIP_COMPANY_ID", "cf4422f9-b895-4918-bbe6-985e841e1ffd")


def scale(usage: dict | None, now: float) -> dict:
    ceiling = cloud_pace.env_float("PACE_SCALE_SESSION_CEILING", 70)
    if usage is None:
        return _tier(0, None, "usage unreadable: baseline")
    week = usage["seven_day"]
    used = float(week["utilization"])
    reset = datetime.fromisoformat(week["resets_at"]).timestamp()
    elapsed = min(100.0, max(0.0, 100 * (1 - (reset - now) / cloud_pace.WEEK)))
    session = float((usage.get("five_hour") or {}).get("utilization") or 0)
    deficit = elapsed - used
    why = f"week {used:.0f}% used, {elapsed:.0f}% elapsed, session {session:.0f}%"
    if session >= ceiling:
        return _tier(0, deficit, f"{why}: session at or over {ceiling:.0f}%: baseline")
    tier = max(i for i, t in enumerate(TIERS) if deficit > t[0])
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
        result = _tier(0, None, f"usage unparseable ({type(exc).__name__}): baseline")
    if "--apply" in sys.argv[1:]:
        try:
            result["applied"] = apply(result)
        except Exception as exc:
            result["applied"] = [f"apply failed: {type(exc).__name__}: {exc}"]
    print(json.dumps(result))
    return 0


if __name__ == "__main__":
    sys.exit(main())
