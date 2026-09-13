#!/usr/bin/env python3
"""How many cloud verifies the weekly usage limit can afford right now.

Prints one integer: the number of cloud-verify sessions allowed in flight. The
cloud lane spends the same account quota as every local agent, so it is paced
against the weekly window rather than bounded by a fixed number: when usage is
behind where an even spend would put it, the surplus goes to cloud verifies;
when usage is on or ahead of pace, the lane closes and the local build box
carries the queue as it always has.

    target_now = elapsed_fraction_of_week * CLOUD_PACE_TARGET
    deficit    = target_now - weekly_utilization          (percentage points)
    slots      = 0 if deficit <= 0 else min(MAX, 1 + deficit // STEP)

The window is read from the usage response's own `resets_at`, never from a
hardcoded weekday, so a moved reset cannot desynchronise the pacing.

FAILS CLOSED. Any error reading usage prints 0. A pacing gate that opens when
it cannot see the meter is how a lane meant to spend *spare* quota exhausts the
whole week and stalls every agent until the reset. The endpoint is the one
Claude Code's own usage display reads; it is not a published API, so a changed
shape is expected eventually and must degrade to "lane off", not to a crash
that a caller might read as permission.

The session (five-hour) limit is a separate ceiling for the same reason: a
week with plenty of headroom can still hit the session limit, and that blocks
the local agents too.
"""

import json
import os
import sys
import time
import urllib.request
from datetime import datetime

USAGE_URL = "https://api.anthropic.com/api/oauth/usage"
WEEK = 7 * 24 * 3600


def env_float(name: str, default: float) -> float:
    try:
        return float(os.environ.get(name, default))
    except ValueError:
        return default


def read_usage() -> dict:
    injected = os.environ.get("CLOUD_PACE_USAGE_FILE")
    if injected:
        with open(injected) as f:
            return json.load(f)
    creds = os.path.expanduser(
        os.environ.get("CLOUD_PACE_CREDENTIALS", "~/.claude/.credentials.json")
    )
    with open(creds) as f:
        token = json.load(f)["claudeAiOauth"]["accessToken"]
    req = urllib.request.Request(
        USAGE_URL,
        headers={
            "Authorization": f"Bearer {token}",
            "anthropic-beta": "oauth-2025-04-20",
        },
    )
    with urllib.request.urlopen(req, timeout=10) as resp:
        return json.load(resp)


def slots(usage: dict, now: float) -> tuple[int, str]:
    target = env_float("CLOUD_PACE_TARGET", 95)
    step = env_float("CLOUD_PACE_STEP", 5)
    cap = int(env_float("CLOUD_PACE_MAX", 4))
    session_ceiling = env_float("CLOUD_PACE_SESSION_CEILING", 80)

    week = usage["seven_day"]
    used = float(week["utilization"])
    reset = datetime.fromisoformat(week["resets_at"]).timestamp()
    elapsed = min(1.0, max(0.0, 1 - (reset - now) / WEEK))
    session = float((usage.get("five_hour") or {}).get("utilization") or 0)

    target_now = elapsed * target
    deficit = target_now - used
    why = (
        f"week {used:.0f}% used, {elapsed * 100:.0f}% elapsed, "
        f"pace {target_now:.0f}%, deficit {deficit:+.1f}pt, session {session:.0f}%"
    )
    if session >= session_ceiling:
        return 0, f"{why}: session ceiling {session_ceiling:.0f}% reached"
    if used >= target or deficit <= 0:
        return 0, f"{why}: on or ahead of pace"
    return min(cap, 1 + int(deficit // step)), why


def main() -> int:
    now = env_float("CLOUD_PACE_NOW", time.time())
    try:
        n, why = slots(read_usage(), now)
    except Exception as exc:  # fail closed on every read or shape error
        n, why = 0, f"usage unreadable ({type(exc).__name__}: {exc}): lane closed"
    print(n)
    print(f"cloud-pace: {n} slot(s) — {why}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
