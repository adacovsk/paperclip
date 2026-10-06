#!/usr/bin/env python3
"""Turn the nightly run's stage logs into the Tester's result JSON.

Usage: parse-nightly.py <state-dir> <sha> <last-green-sha>

Reads `<state-dir>/<stage>.log` and `<stage>.exit` for each stage `run-nightly.sh`
ran. Kept out of the agent so the facts the Tester files issues from — which
lint, which test, what it panicked with — are extracted the same way every night
rather than re-read from a multi-thousand-line log by a model.
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

CLIPPY_STAGES = ("clippy-default", "clippy-no-default-features")
TEST_STAGE = "test"

RUNNING = re.compile(r"^\s+Running (?:unittests )?(\S+)")
FAILED = re.compile(r"^test (\S+) \.\.\. FAILED$")
STDOUT_HEADER = re.compile(r"^---- (\S+) stdout ----$")
DIAGNOSTIC = re.compile(r"^(error|warning)(\[\S+\])?: (.*)$")
LOCATION = re.compile(r"^\s+--> (\S+)")
RESULT = re.compile(r"^test result: ")

#: cargo's own summary lines share the diagnostic prefix but name no problem.
CARGO_SUMMARY = re.compile(
    r"^(error: (could not compile|test failed|aborting due to|.*previous errors?)"
    r"|warning: .*(generated \d+ warnings?|warnings? emitted))"
)

#: Lines of a failing test's captured output kept for the issue body. The panic
#: message and the assertion's left/right are near the top; the rest is noise.
PANIC_LINES = 12

#: Diagnostics kept per clippy stage. One bad macro can emit hundreds of the same
#: lint, and the issue needs the distinct ones, not the count.
MAX_DIAGNOSTICS = 60


def target_name(path: str) -> str:
    """`tests/active_modifiers/main.rs` -> `active_modifiers`; `src/lib.rs` -> `lib`."""
    p = Path(path)
    if p.parts and p.parts[0] == "tests":
        return p.parent.name if p.name == "main.rs" else p.stem
    return "lib" if p.name == "lib.rs" else p.stem


def diagnostics(lines: list[str]) -> list[dict]:
    """Every distinct compiler/clippy diagnostic, with its first source location."""
    found: list[dict] = []
    seen: set[tuple[str, str | None]] = set()
    for i, line in enumerate(lines):
        if CARGO_SUMMARY.match(line) or not (m := DIAGNOSTIC.match(line)):
            continue
        loc = next((lm.group(1) for l in lines[i + 1 : i + 4] if (lm := LOCATION.match(l))), None)
        key = (line, loc)
        if key in seen:
            continue
        seen.add(key)
        found.append({"level": m.group(1), "code": (m.group(2) or "").strip("[]") or None,
                      "message": m.group(3), "location": loc})
    return found[:MAX_DIAGNOSTICS]


def parse_tests(lines: list[str]) -> dict:
    target = None
    failed: list[dict] = []
    panics: dict[tuple[str | None, str], list[str]] = {}
    results: list[str] = []
    capturing: tuple[str | None, str] | None = None

    for line in lines:
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
        if RESULT.match(line):
            results.append(f"{target}: {line}")

    for f in failed:
        f["output"] = "\n".join(panics.get((f["target"], f["test"]), [])).strip()
    return {"failed": failed, "results": results}


def stage(state: Path, name: str) -> dict:
    exit_file, log_file = state / f"{name}.exit", state / f"{name}.log"
    if not exit_file.is_file():
        return {"exit": None, "ran": False}
    rc = int(exit_file.read_text().strip())
    lines = log_file.read_text(encoding="utf-8", errors="replace").splitlines() if log_file.is_file() else []
    errors = [d for d in diagnostics(lines) if d["level"] == "error"]
    out: dict = {"exit": rc, "ran": True}
    if name == TEST_STAGE:
        out.update(parse_tests(lines))
        out["compile_errors"] = errors
        # A target that failed to build never ran, so "not in `failed`" proves
        # nothing about it. 101 is cargo's "some test failed" status.
        out["complete"] = rc in (0, 101) and not errors
    else:
        # Under `-D warnings` every lint is an error, so the error list is the
        # complete verdict; warnings left over are the allowed `-A` classes.
        out["diagnostics"] = errors
    if rc not in (0, 101):
        out["log_tail"] = lines[-15:]
    return out


def main() -> int:
    state, sha, last_green = Path(sys.argv[1]), sys.argv[2], sys.argv[3]
    run_exit_file = state / "exit"
    run_exit = int(run_exit_file.read_text().strip()) if run_exit_file.is_file() else 99
    run_log = state / "log"
    json.dump(
        {
            "sha": sha or None,
            "exit": run_exit,
            "last_green": last_green or None,
            "stages": {name: stage(state, name) for name in (*CLIPPY_STAGES, TEST_STAGE)},
            "log_tail": run_log.read_text(errors="replace").splitlines()[-15:]
            if run_exit != 0 and run_log.is_file()
            else [],
        },
        sys.stdout,
        indent=1,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
