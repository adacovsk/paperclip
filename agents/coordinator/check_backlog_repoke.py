#!/usr/bin/env python3
"""Whether re-poking the Planner on an open `Backlog low` task can file anything.

WHY. Coordinator step 9 re-dispatched an open `Backlog low` task on every full
sweep, and the Planner left it open whenever every indexed front was claimed or
held. A re-poke posted a comment and toggled the assignee, so it woke the
Planner once or twice, and the fire found the same claimed fronts again. In
three days 119 of 202 Planner fires started with `origin/main` exactly where it
had been at the fire before.

A front only becomes fileable when something lands: a merge that finishes a
claimed section, releases a hold, or adds sections through the Planner's own
roadmap PR. All of those move `origin/main`. So when `main` has not moved since
the Planner's last fire started, a re-poke reads the same index and claims and
files the same nothing. That is the case this refuses, and only that case.

It fails open. A Planner fire it cannot find, a git read that fails, or a last
fire older than MAX_AGE_S all mean re-poke, so the worst this does is today's
behaviour. MAX_AGE_S bounds what `main` cannot show: a claim released by a
cancelled task, a hold lifted by hand.

Usage: check_backlog_repoke.py   exit 0: re-poke (the reason is printed)
                                  exit 1: skip this sweep (the reason is printed)
Env:   PAPERCLIP_PROJECT (required), PAPERCLIP_COMPANY_ID (required),
       PAPERCLIP_API_URL (default http://127.0.0.1:3100), PAPERCLIP_API_KEY,
       BACKLOG_REPOKE_MAX_AGE_S (default 21600, six hours)
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import urllib.request
from datetime import datetime, timezone

MAX_AGE_S = int(os.environ.get("BACKLOG_REPOKE_MAX_AGE_S", "21600"))


def decide(last_fire: datetime | None, main_then: str | None, main_now: str | None,
           now: datetime, max_age_s: int = MAX_AGE_S) -> tuple[bool, str]:
    """(re-poke?, why). Anything unknown re-pokes."""
    if last_fire is None:
        return True, "no earlier Planner fire on record"
    if not main_then or not main_now:
        return True, "could not read origin/main"
    age = (now - last_fire).total_seconds()
    if age > max_age_s:
        return True, f"the last Planner fire was {age / 3600:.1f}h ago"
    if main_then != main_now:
        return True, f"origin/main moved since the last Planner fire ({main_then[:9]} -> {main_now[:9]})"
    return False, f"origin/main is still {main_now[:9]}, where it was when the last Planner fire started"


def api(path: str):
    base = os.environ.get("PAPERCLIP_API_URL", "http://127.0.0.1:3100").rstrip("/")
    req = urllib.request.Request(base + "/api" + path)
    if os.environ.get("PAPERCLIP_API_KEY"):
        req.add_header("Authorization", f"Bearer {os.environ['PAPERCLIP_API_KEY']}")
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.load(resp)


def last_planner_fire() -> datetime | None:
    company = os.environ["PAPERCLIP_COMPANY_ID"]
    planner = next(a["id"] for a in api(f"/companies/{company}/agents") if a["name"] == "Planner")
    runs = api(f"/companies/{company}/heartbeat-runs?agentId={planner}&limit=10")
    started = [r["startedAt"] for r in runs if r.get("startedAt")]
    return max(datetime.fromisoformat(s.replace("Z", "+00:00")) for s in started) if started else None


def git(*args: str) -> str | None:
    try:
        out = subprocess.run(["git", "-C", os.environ["PAPERCLIP_PROJECT"], *args],
                             capture_output=True, text=True, timeout=120, check=True)
    except (OSError, subprocess.SubprocessError):
        return None
    return out.stdout.strip() or None


def main() -> int:
    try:
        last = last_planner_fire()
    except Exception as exc:  # fail open: an unreadable API is today's re-poke
        print(f"re-poke: cannot read the Planner's runs ({exc})")
        return 0
    git("fetch", "-q", "origin", "main")
    now_sha = git("rev-parse", "origin/main")
    then_sha = git("rev-list", "-1", "--first-parent", f"--before={last.isoformat()}", "origin/main") if last else None
    repoke, why = decide(last, then_sha, now_sha, datetime.now(timezone.utc))
    print(("re-poke: " if repoke else "skip: ") + why)
    return 0 if repoke else 1


if __name__ == "__main__":
    sys.exit(main())
