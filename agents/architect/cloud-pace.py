#!/usr/bin/env python3
"""Whether the weekly usage limit has quota to spare: the pipeline's one quota gate.

Prints 1 (lane open) or 0 (lane closed). The lane is open until weekly usage
reaches WEEK_CEILING. While it is open every verify goes to the cloud with no
concurrency bound and the Coordinator's `pace-scale.py` runs supply at full
width; once it closes, the local build box carries the verify queue and
promotion of new work stops, so the quota left under the ceiling lands finished
work. The ceiling sits below 100 because an exhausted weekly limit stalls every
agent, not just the verifies.

ONE GATE, ONE NUMBER. Every caller that throttles on quota reads this script,
and the ceiling is a constant here, not an environment variable. When it was a
per-agent variable, raising it on the Architect and Dispatcher left the Planner
on the old default: the Planner read the lane as closed and stopped writing
supply while the Architect was launching cloud verifies on the same reading.
A second throttle in another script does the same thing with different
numbers -- a pace-deficit tier set narrowed supply at 91% while this lane was
open -- so do not add one. Spending the week up to the ceiling is the
operator's standing choice; pace against the calendar is not compared.

The window is read from the usage response's own `resets_at`, never from a
hardcoded weekday, so a moved reset cannot desynchronise the gate.

FAILS CLOSED. Any error reading usage prints 0. An unbounded lane that opens
when it cannot see the meter is how a week's quota is exhausted and every agent
stalls until the reset. The endpoint is the one Claude Code's own usage display
reads; it is not a published API, so a changed shape is expected eventually and
must degrade to "lane off", not to a crash a caller might read as permission.

The five-hour session limit does not gate the lane. It resets within hours,
so hitting it costs an afternoon; only the weekly limit can stall the agents
for days. Do not re-add a session ceiling here: closing on it sends verifies
to the local box while the week still has headroom.

CACHED, BECAUSE THE METER RATE-LIMITS. Every launch, offload and re-verify asks
this gate, and the endpoint answers HTTP 429 once asked often enough. Uncached,
the pipeline rate-limited itself into a permanently closed lane: 210 consecutive
429s in the log, and every verify queued on one local slot. A successful reading
is cached for CLOUD_PACE_CACHE_TTL seconds (default 300) and reused without a
request. When a request fails, a cached reading no older than
CLOUD_PACE_STALE_MAX seconds (default 900) is used in its place; older than that,
the gate fails closed as before. Usage only rises, so a stale reading can only
under-read it, by at most fifteen minutes of spend, and the two points between
the ceiling and 100% absorb that.
"""

import json
import os
import sys
import time
import urllib.request
from datetime import datetime

USAGE_URL = os.environ.get("CLOUD_PACE_URL", "https://api.anthropic.com/api/oauth/usage")
CACHE = os.path.expanduser(
    os.environ.get(
        "CLOUD_PACE_CACHE",
        os.path.join(os.environ.get("XDG_CACHE_HOME", "~/.cache"), "paperclip-verify", "usage-cache.json"),
    )
)
WEEK = 7 * 24 * 3600
#: Weekly utilization (percent) at which the lane closes. The only quota threshold in the pipeline.
WEEK_CEILING = 98.0


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
    ttl = env_float("CLOUD_PACE_CACHE_TTL", 300)
    stale_max = env_float("CLOUD_PACE_STALE_MAX", 900)
    age = cache_age()
    if age is not None and age <= ttl:
        with open(CACHE) as f:
            return json.load(f)
    try:
        usage = fetch_usage()
    except Exception:
        if age is not None and age <= stale_max:
            with open(CACHE) as f:
                return json.load(f)
        raise
    tmp = f"{CACHE}.{os.getpid()}"
    os.makedirs(os.path.dirname(CACHE), exist_ok=True)
    with open(tmp, "w") as f:
        json.dump(usage, f)
    os.replace(tmp, CACHE)
    return usage


def cache_age() -> float | None:
    """Seconds since the cached reading was written, or None if there is none."""
    try:
        return time.time() - os.path.getmtime(CACHE)
    except OSError:
        return None


def fetch_usage() -> dict:
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
    week = usage["seven_day"]
    used = float(week["utilization"])
    reset = datetime.fromisoformat(week["resets_at"]).timestamp()
    elapsed = min(100.0, max(0.0, 100 * (1 - (reset - now) / WEEK)))

    why = f"week {used:.0f}% used, {elapsed:.0f}% elapsed"
    if used >= WEEK_CEILING:
        return False, f"{why}: week ceiling {WEEK_CEILING:.0f}% reached"
    return True, f"{why}: under the ceiling"


def is_open_now() -> tuple[bool, str]:
    """The gate's answer for this moment, failing closed on any read or shape error."""
    now = env_float("CLOUD_PACE_NOW", time.time())
    try:
        return is_open(read_usage(), now)
    except Exception as exc:
        return False, f"usage unreadable ({type(exc).__name__}: {exc})"


def main() -> int:
    open_, why = is_open_now()
    print(1 if open_ else 0)
    print(f"cloud-pace: {'open' if open_ else 'closed'} — {why}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
