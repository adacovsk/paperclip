#!/usr/bin/env python3
"""Whether the weekly usage limit has quota to spare on cloud verifies.

Prints 1 (lane open) or 0 (lane closed). The lane is open until a ceiling is
reached: the five-hour session ceiling (CLOUD_PACE_SESSION_CEILING, default 80)
or the week ceiling (CLOUD_PACE_WEEK_CEILING, default 90). While it is open every
verify goes to the cloud with no concurrency bound; once it closes, the local
build box (the Architect's local chain) carries the queue. The week ceiling sits
below 100 because an exhausted weekly limit stalls every local agent too, not
just the verifies.

The operator's standing choice is the cloud for everything a ceiling allows, so
pace is not compared by default. CLOUD_PACE_ENFORCE_PACE=1 restores the pacing
gate: the lane is then open only while weekly utilization is behind the
fraction of the week elapsed, so spend tracks the calendar.

The window is read from the usage response's own `resets_at`, never from a
hardcoded weekday, so a moved reset cannot desynchronise the gate.

FAILS CLOSED. Any error reading usage prints 0. An unbounded lane that opens
when it cannot see the meter is how a week's quota is exhausted and every agent
stalls until the reset. The endpoint is the one Claude Code's own usage display
reads; it is not a published API, so a changed shape is expected eventually and
must degrade to "lane off", not to a crash a caller might read as permission.

Unreadable usage fails closed whether or not pace is enforced.

The session (five-hour) limit is a separate ceiling for the same reason: a
week with plenty of headroom can still hit the session limit, and that blocks
the local agents too.

CACHED, BECAUSE THE METER RATE-LIMITS. Every launch, offload and re-verify asks
this gate, and the endpoint answers HTTP 429 once asked often enough. Uncached,
the pipeline rate-limited itself into a permanently closed lane: 210 consecutive
429s in the log, and every verify queued on one local slot. A successful reading
is cached for CLOUD_PACE_CACHE_TTL seconds (default 300) and reused without a
request. When a request fails, a cached reading no older than
CLOUD_PACE_STALE_MAX seconds (default 900) is used in its place; older than that,
the gate fails closed as before. Usage only rises, so a stale reading can only
under-read it, by at most fifteen minutes of spend, and the session and week
ceilings sit well below 100% to absorb that.
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
    session_ceiling = env_float("CLOUD_PACE_SESSION_CEILING", 80)

    week = usage["seven_day"]
    used = float(week["utilization"])
    reset = datetime.fromisoformat(week["resets_at"]).timestamp()
    elapsed = min(100.0, max(0.0, 100 * (1 - (reset - now) / WEEK)))
    session = float((usage.get("five_hour") or {}).get("utilization") or 0)

    why = f"week {used:.0f}% used, {elapsed:.0f}% elapsed, session {session:.0f}%"
    if session >= session_ceiling:
        return False, f"{why}: session ceiling {session_ceiling:.0f}% reached"
    if os.environ.get("CLOUD_PACE_ENFORCE_PACE") == "1":
        if used >= elapsed:
            return False, f"{why}: on or ahead of pace"
        return True, f"{why}: behind pace"
    week_ceiling = env_float("CLOUD_PACE_WEEK_CEILING", 90)
    if used >= week_ceiling:
        return False, f"{why}: week ceiling {week_ceiling:.0f}% reached"
    return True, f"{why}: under the ceilings"


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
