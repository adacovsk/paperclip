#!/usr/bin/env python3
"""Which tasks already claim a roadmap section — the duplicate-dispatch check.

Usage:
    section-claims.py <section> --title <candidate title> [--exclude AA-<n>] [--days 7]
        [--issues-json FILE]

Prints one line per claiming task and exits:
    0  no claim — the candidate may be filed or promoted
    1  claimed — do not file; at promotion, the candidate is the duplicate
    2  the task list could not be read — treat as claimed (fail closed)

A task claims `<section>` when it is live (any status but `cancelled`, or `done` within
`--days`) and any of these holds:

* its title or body names `§<section>` (or a `Section: §<section>` line);
* its normalised title equals the candidate's, or one contains the other.

The title match exists because a task can be filed with no section at all: the second
task for §4.1020 carried neither `§4.1020` nor a `Source:` anchor, only the first task's
title without its `(§4.1020)` suffix. A section-number search cannot see that task, and
it reached an open PR beside the first one.

Stage subtasks (`Review:`, `Verify:`, anything with a parent) are part of their parent's
claim, not claims of their own, and are ignored.

A multi-slice front is meant to have several tasks — "overlap is the slice, not the
section number" — so pass `--slice` for one. It then admits one slice *in flight* at a
time: any not-yet-`done` task on the section claims it, open PR included, while a `done`
slice claims it only if it names one of the candidate's `--paths`. One-at-a-time is the
rule because an open-ended front ("the next dozen files") does not say which files a slice
takes; the Worker picks them, so two slices in flight at once pick the same dozen. That is
how §4.990 produced two PRs over identical files.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone

COMPANY = os.environ.get("PAPERCLIP_COMPANY_ID", "cf4422f9-b895-4918-bbe6-985e841e1ffd")
API = os.environ.get("PAPERCLIP_API_URL", "http://localhost:3100").rstrip("/")

#: Words that differ between two filings of the same front without changing what it is.
_NOISE = re.compile(r"\(§\s*\d+(?:\.\d+)*\)|§\s*\d+(?:\.\d+)*\s*[—–-]?|`|\*\*")


def normalise(title: str) -> str:
    t = _NOISE.sub(" ", title.lower())
    t = re.sub(r"[^a-z0-9]+", " ", t)
    return " ".join(t.split())


def fetch(query: str) -> list[dict]:
    url = f"{API}/api/companies/{COMPANY}/issues?" + urllib.parse.urlencode({"q": query})
    headers = {}
    if key := os.environ.get("PAPERCLIP_API_KEY"):
        headers["Authorization"] = f"Bearer {key}"
    with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=30) as r:
        data = json.load(r)
    return data if isinstance(data, list) else data.get("issues", [])


def is_live(issue: dict, days: int, now: datetime) -> bool:
    status = issue.get("status")
    if status == "cancelled":
        return False
    if status != "done":
        return True
    stamp = issue.get("completedAt") or issue.get("updatedAt") or ""
    try:
        when = datetime.fromisoformat(stamp.replace("Z", "+00:00"))
    except ValueError:
        return True  # an unreadable date is not evidence the claim lapsed
    return now - when <= timedelta(days=days)


def claims(issues: list[dict], section: str, title: str, exclude: str | None,
           days: int, now: datetime, slice_paths: list[str] | None = None) -> list[tuple[dict, str]]:
    sec = re.compile(rf"§\s*{re.escape(section)}(?![\d.])")
    want = normalise(title)
    found: dict[str, tuple[dict, str]] = {}
    for issue in issues:
        ident = issue.get("identifier", "")
        if ident == exclude or ident in found or not is_live(issue, days, now):
            continue
        if issue.get("parentId") or re.match(r"(Review|Verify|ci-fix):", issue.get("title", "")):
            continue
        text = f"{issue.get('title', '')}\n{issue.get('description') or ''}"
        have = normalise(issue.get("title", ""))
        if sec.search(text):
            if slice_paths is None:
                found[ident] = (issue, f"names §{section}")
            elif issue.get("status") != "done":
                found[ident] = (issue, f"slice of §{section} still in flight")
            elif shared := [p for p in slice_paths if p in text]:
                found[ident] = (issue, f"done slice of §{section} already took {shared[0]}")
            continue
        if want and have and (want == have or want in have or have in want):
            found[ident] = (issue, "same title")
    return list(found.values())


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("section", help="roadmap section number, e.g. 4.1020 (a leading § is ignored)")
    p.add_argument("--title", required=True, help="the candidate task's title")
    p.add_argument("--exclude", help="the candidate's own identifier, when it already exists")
    p.add_argument("--days", type=int, default=7, help="how long a done task keeps its claim")
    p.add_argument("--slice", action="store_true", help="the section is a multi-slice front")
    p.add_argument("--paths", nargs="*", default=[], help="the candidate's Where: paths (with --slice)")
    p.add_argument("--issues-json", help="read the task list from FILE instead of the API (tests)")
    args = p.parse_args(argv)
    section = args.section.lstrip("§").strip()

    try:
        if args.issues_json:
            with open(args.issues_json, encoding="utf-8") as fh:
                issues = json.load(fh)
        else:
            # Two narrow searches, not one listing: by section number, and by the
            # title's leading words (which a section-less duplicate still shares).
            words = " ".join(normalise(args.title).split()[:5])
            issues = fetch(section) + (fetch(words) if words else [])
    except (OSError, ValueError) as exc:
        print(f"section-claims: cannot read tasks ({exc}) — treat §{section} as claimed", file=sys.stderr)
        return 2

    found = claims(issues, section, args.title, args.exclude, args.days, datetime.now(timezone.utc),
                   args.paths if args.slice else None)
    for issue, why in found:
        print(f"{issue.get('identifier')}\t{issue.get('status')}\t{why}\t{issue.get('title', '')[:90]}")
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main())
