#!/usr/bin/env python3
"""Whether the weekly usage limit has quota to spare on cloud verifies.

Prints 1 (lane open) or 0 (lane closed). Open means weekly utilization is
behind the fraction of the week that has elapsed — quota an even spend would
already have used is going unused — and while it is, every verify goes to the
cloud with no concurrency bound. The deficit self-corrects: cloud sessions
spend the same account quota, so a flood closes the lane once usage catches up
with the calendar, and the local build box carries the queue again.

The window is read from the usage response's own `resets_at`, never from a
hardcoded weekday, so a moved reset cannot desynchronise the gate.

FAILS CLOSED. Any error reading usage prints 0. An unbounded lane that opens
when it cannot see the meter is how a week's quota is exhausted and every agent
stalls until the reset. The endpoint is the one Claude Code's own usage display
reads; it is not a published API, so a changed shape is expected eventually and
must degrade to "lane off", not to a crash a caller might read as permission.

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


def is_open(usage: dict, now: float) -> tuple[bool, str]:
    session_ceiling = env_float("CLOUD_PACE_SESSION_CEILING", 80)

    week = usage["seven_day"]
    used = float(week["utilization"])
    reset = datetime.fromisoformat(week["resets_at"]).timestamp()
    elapsed = min(100.0, max(0.0, 100 * (1 - (reset - now) / WEEK)))
    session = float((usage.get("five_hour") or {}).get("utilization") or 0)

    why = f"week {used:.0f}% used, {elapsed:.0f}% elapsed, session {session:.0f}%"
    if session >= session_ceiling:
        return False, f"{why}: session ceiling {session_ceiling:.0f}% reached"
    if used >= elapsed:
        return False, f"{why}: on or ahead of pace"
    return True, f"{why}: behind pace"


def main() -> int:
    now = env_float("CLOUD_PACE_NOW", time.time())
    try:
        open_, why = is_open(read_usage(), now)
    except Exception as exc:  # fail closed on every read or shape error
        open_, why = False, f"usage unreadable ({type(exc).__name__}: {exc})"
    print(1 if open_ else 0)
    print(f"cloud-pace: {'open' if open_ else 'closed'} — {why}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
