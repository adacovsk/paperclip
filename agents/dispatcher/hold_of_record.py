#!/usr/bin/env python3
"""Print a blocked task's hold of record: its newest comment and its newest `Held:` line.

`GET /api/issues/:id/comments` returns comments NEWEST FIRST. Reading the list's
last element as "the latest" therefore reads the OLDEST comment, and a release
judged against the oldest `Held:` line releases on a reason a later hold has
already replaced. Order by `createdAt` here instead of trusting list position.

Usage: hold_of_record.py <identifier>...   (e.g. AA-13446)
Env:   PAPERCLIP_API_URL (default http://localhost:3100)

Output, one block per task:
  <identifier> newest:      <first line of the newest comment>
  <identifier> newest-held: <first line of the newest `Held:` comment, or (none)>
  <identifier> WARNING: newest comment is not a `Held:` line ...   (when they differ)

The WARNING case matters to the Dispatcher too: it reads only the newest comment,
so a hold followed by any other comment is invisible to its release sweep. A
comment that keeps a hold in force must therefore restate the `Held:` line as
its own first line.
"""

import json
import os
import sys
import urllib.request

HELD = "Held:"


def first_line(body: str | None) -> str:
    return (body or "").strip().split("\n", 1)[0]


def hold_of_record(comments: list[dict]) -> tuple[dict | None, dict | None]:
    """(newest comment, newest comment whose first line starts with `Held:`), by createdAt."""
    ordered = sorted(comments, key=lambda c: c["createdAt"])
    newest = ordered[-1] if ordered else None
    held = next((c for c in reversed(ordered) if first_line(c.get("body")).startswith(HELD)), None)
    return newest, held


def report(identifier: str, comments: list[dict]) -> list[str]:
    newest, held = hold_of_record(comments)
    lines = [
        f"{identifier} newest:      {first_line(newest['body']) if newest else '(no comments)'}",
        f"{identifier} newest-held: {first_line(held['body']) if held else '(none)'}",
    ]
    if held is not None and newest is not held:
        lines.append(
            f"{identifier} WARNING: newest comment is not a `Held:` line; the Dispatcher cannot see this hold"
        )
    return lines


def main(argv: list[str]) -> int:
    if not argv:
        print(__doc__.split("\n\n")[2], file=sys.stderr)
        return 2
    base = os.environ.get("PAPERCLIP_API_URL", "http://localhost:3100").rstrip("/")
    for identifier in argv:
        with urllib.request.urlopen(f"{base}/api/issues/{identifier}/comments") as resp:
            comments = json.load(resp)
        print("\n".join(report(identifier, comments)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
