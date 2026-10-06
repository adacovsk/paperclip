#!/usr/bin/env python3
"""Turn a `cargo test --tests --no-fail-fast` log into the Tester's result JSON.

Usage: parse-test-log.py <log> <exit-status> <sha> <last-green-sha>

Kept out of the agent so the facts the Tester files issues from — which target,
which test, what it panicked with — are extracted the same way every night
rather than re-read from a multi-thousand-line log by a model.
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

RUNNING = re.compile(r"^\s+Running (?:unittests )?(\S+)")
FAILED = re.compile(r"^test (\S+) \.\.\. FAILED$")
STDOUT_HEADER = re.compile(r"^---- (\S+) stdout ----$")
COMPILE_ERROR = re.compile(r"^error(\[E\d+\])?: ")
LOCATION = re.compile(r"^\s+--> (\S+)")
RESULT = re.compile(r"^test result: ")

#: Lines of a failing test's captured output kept for the issue body. The panic
#: message and the assertion's left/right are near the top; the rest is noise.
PANIC_LINES = 12


def target_name(path: str) -> str:
    """`tests/active_modifiers/main.rs` -> `active_modifiers`; `src/lib.rs` -> `lib`."""
    p = Path(path)
    if p.parts and p.parts[0] == "tests":
        return p.parent.name if p.name == "main.rs" else p.stem
    return "lib" if p.name == "lib.rs" else p.stem


def parse(lines: list[str]) -> dict:
    target = None
    failed: list[dict] = []
    panics: dict[tuple[str | None, str], list[str]] = {}
    compile_errors: list[str] = []
    results: list[str] = []
    capturing: tuple[str | None, str] | None = None

    for i, line in enumerate(lines):
        if m := RUNNING.match(line):
            target, capturing = target_name(m.group(1)), None
            continue
        if m := FAILED.match(line):
            failed.append({"target": target, "test": m.group(1)})
            continue
        if m := STDOUT_HEADER.match(line):
            capturing = (target, m.group(1))
            panics[capturing] = []
            continue
        if capturing is not None:
            # The per-test stdout sections end at the bare list of failed names.
            # A backtrace is the harness's frames, not the test's; drop the rest.
            if line.strip() in ("failures:", "stack backtrace:"):
                capturing = None
            elif len(panics[capturing]) < PANIC_LINES:
                panics[capturing].append(line)
            continue
        if COMPILE_ERROR.match(line) and not line.startswith("error: test failed"):
            loc = next((m.group(1) for l in lines[i + 1 : i + 4] if (m := LOCATION.match(l))), None)
            compile_errors.append(f"{line} ({loc})" if loc else line)
            continue
        if RESULT.match(line):
            results.append(f"{target}: {line}")

    for f in failed:
        f["output"] = "\n".join(panics.get((f["target"], f["test"]), [])).strip()
    return {
        "failed": failed,
        "compile_errors": compile_errors,
        "results": results,
    }


def main() -> int:
    log, rc, sha, last_green = sys.argv[1:5]
    text = Path(log).read_text(encoding="utf-8", errors="replace") if Path(log).is_file() else ""
    parsed = parse(text.splitlines())
    json.dump(
        {
            "sha": sha or None,
            "exit": int(rc),
            "last_green": last_green or None,
            # A run with compile errors never executed the targets that failed to
            # build, so "not in `failed`" proves nothing about them.
            "complete": int(rc) in (0, 101) and not parsed["compile_errors"],
            **parsed,
            "log_tail": text.splitlines()[-15:] if int(rc) not in (0, 101) else [],
        },
        sys.stdout,
        indent=1,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
