#!/usr/bin/env python3
"""Decide whether a green verify must be rebuilt because origin/main moved under it.

Usage:  freshness_interaction.py <verified-base> <new-base>   (run inside the task worktree)
Exit:   0  re-verify: main's advance can interact with this branch (or it cannot be told)
        1  no re-verify: nothing main changed can reach what the branch changed
Prints one line naming the rule that decided to stderr, and appends it to
$XDG_CACHE_HOME/paperclip-verify/freshness.log.

WHY. A green build stands for the tree it built. The question at landing is
whether main's advance since that build can change the result, and the answer
is "only where the two diffs meet". Rebuilding on any code change answered a
different question, "did main move?", which on a busy day is always yes: about
half of the green verifies went back out for a rebuild, the rebuild was usually
overtaken again, and the cap then landed it unbuilt anyway. That spent a cloud
build per landing and still checked nothing at the cap.

Where two diffs meet, in the order checked:
  build-wide   main changed what every build reads (Cargo.toml, Cargo.lock, the
               toolchain, build.rs): everything can move.
  same file    both changed one file. New tests beside the code, a changed
               signature, a newly required resource: the commonest way a clean
               textual merge hides a red composition.
  same data    both changed one dataset: a directory under assets/data, or a
               top-level data file. Whole-dataset invariants (a ceiling over every
               monster, one placement per environment) are where two individually
               green data changes add up red.
  data reader  one side changed data and the other changed the Rust that loads it.
  symbol       a Rust item one side defines or edits (fn, type, field, variant, a
               trait it implements, or the item a hunk sits in), or a data key one
               side writes, is named on a line the other side changed. This is the
               cross-file case: the branch changes a type and main adds a caller
               elsewhere. Only names that localize count (see `distinctive`).

Generated schemas (assets/schemas/) count on neither side: they are outputs of
doc comments, and whether they are current is a landing-gate check with no build.

What none of these sees: an interaction through no shared file, directory or
name, such as system ordering in an unrelated plugin. The nightly Tester is the
backstop for that, as it is for the freshness cap.

FAIL CLOSED. A git error, an unreadable base, a branch that descends from
neither base, or a data file no Rust names all re-verify. Wrongly skipping a
re-verify can land an untested interaction; wrongly running one costs a build.
"""
from __future__ import annotations

import os
import re
import subprocess
import sys
import time
from pathlib import Path, PurePosixPath

BUILD_WIDE = re.compile(
    r"^(Cargo\.toml|Cargo\.lock|build\.rs|rust-toolchain(\.toml)?|clippy\.toml|\.cargo/.*|"
    r"pixi\.toml|pixi\.lock)$"
)
DATA = "assets/data/"
#: A snake_case name in more Rust files than this localizes nothing: `name`,
#: `level`, `new`. CamelCase type names are always distinctive.
COMMON_FILES = 30
DEFINES = re.compile(
    r"\b(?:fn|struct|enum|trait|type|const|static|mod|union)\s+([A-Za-z_]\w*)|"
    r"macro_rules!\s*([A-Za-z_]\w*)|"
    # From an impl line only the trait: two branches adding `impl Trait for X`
    # conflict, while an inherent `impl X {` only adds methods, named on their own.
    r"\bimpl(?:<[^>]*>)?\s+([A-Za-z_]\w*)(?:<[^>]*>)?\s+for\b"
)
FIELD = re.compile(r"^\s*(?:pub(?:\([^)]*\))?\s+)?([a-z_][a-z0-9_]*)\s*:[^:]")
VARIANT = re.compile(r"^\s*([A-Z][A-Za-z0-9]*)\s*(?:[({,=]|$)")
JSON_KEY = re.compile(r'"([A-Za-z_][A-Za-z0-9_]*)"\s*:')
WORD = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
#: The item a hunk sits in. An `impl` header is not one: adding a method to a
#: type breaks none of the code that names it.
ITEM = re.compile(
    r"\b(?:fn|struct|enum|trait|type|const|static|mod|union)\s+([A-Za-z_]\w*)|macro_rules!\s*([A-Za-z_]\w*)"
)
#: Generated from doc comments by the schema generator: an output, not an input.
#: Whether the committed schemas are current is the landing gate's check, and it
#: needs no build, so two branches regenerating one schema is not an interaction.
GENERATED = "assets/schemas/"
HUNK = re.compile(r"^@@ [^@]* @@ ?(.*)$")
RUST_ATTRS = None  # path of a gitattributes file mapping *.rs to git's rust diff driver


class GitError(Exception):
    pass


def git(*args: str) -> str:
    cmd = ["git"]
    if RUST_ATTRS:
        cmd += ["-c", f"core.attributesFile={RUST_ATTRS}"]
    out = subprocess.run(cmd + list(args), capture_output=True, text=True)
    if out.returncode != 0:
        raise GitError(" ".join(args))
    return out.stdout


def is_ancestor(a: str, b: str) -> bool:
    return subprocess.run(["git", "merge-base", "--is-ancestor", a, b], capture_output=True).returncode == 0


def grep_hits(needles: list[str], rev: str, word: bool = False, regex: bool = False) -> dict[str, set[str]]:
    """{matched text: files at `rev` under src/, tests/, benches/ or build.rs that contain it}, in one git grep.

    One call for every needle rather than one per needle: git grep against a
    commit is single-threaded and decompresses each blob, so per-needle calls
    cost seconds apiece under build load, inside a landing that has to be quick.
    """
    if not needles:
        return {}
    cmd = ["git", "grep", "-o", "-I", "-E" if regex else "-F"] + (["-w"] if word else [])
    for n in needles:
        cmd += ["-e", n]
    cmd += [rev, "--", "src/*", "tests/*", "benches/*", "build.rs"]
    out = subprocess.run(cmd, capture_output=True, text=True)
    if out.returncode > 1:
        raise GitError("grep")
    hits: dict[str, set[str]] = {}
    for line in out.stdout.splitlines():
        path, _, match = line[len(rev) + 1:].partition(":")
        hits.setdefault(match, set()).add(path)
    return hits


def code_paths(paths: list[str], new: str) -> list[str]:
    """`paths` minus documentation, which no build or test reads."""
    def doc(p: str) -> bool:
        return p.startswith("docs/") or p.endswith(".md") or p == "scripts/roadmap_section_baseline.txt"
    rest = [p for p in paths if not doc(p)]
    # A file under scripts/ is a build input only if Rust names it: cargo tests
    # read a handful of guard scripts by literal path.
    scripts = [p for p in rest if p.startswith("scripts/")]
    named = grep_hits(scripts, new)
    return [p for p in rest if not p.startswith("scripts/") or p in named]


def changed(a: str, b: str) -> list[str]:
    return [p for p in git("diff", "--name-only", a, b).splitlines() if p]


def changed_lines(a: str, b: str, paths: list[str]) -> tuple[list[str], list[str]]:
    """(changed code lines, enclosing-item hunk headers) of the Rust and data files in `paths`."""
    wanted = [p for p in paths if p.endswith(".rs") or (p.startswith(DATA) and p.endswith(".json"))]
    if not wanted:
        return [], []
    lines, headers = [], []
    for line in git("diff", "-U0", "--no-color", a, b, "--", *wanted).splitlines():
        if line.startswith(("+++", "---")):
            continue
        m = HUNK.match(line)
        if m:
            headers.append(m.group(1))
        elif line[:1] in "+-":
            body = line[1:]
            if not body.strip().startswith("//"):  # a comment edit changes no behaviour
                lines.append(body)
    return lines, headers


def symbols(lines: list[str], headers: list[str]) -> set[str]:
    out: set[str] = set()
    for text in lines:
        for m in DEFINES.finditer(text):
            out.update(g for g in m.groups() if g)
    for text in headers:
        for m in ITEM.finditer(text):
            out.update(g for g in m.groups() if g)
    for text in lines:
        for rx in (FIELD, VARIANT):
            m = rx.match(text)
            if m:
                out.add(m.group(1))
        out.update(JSON_KEY.findall(text))
    return out


def distinctive(names: set[str], new: str) -> set[str]:
    """The names that can localize an interaction.

    A type or trait this repository defines always can: changing `Condition`
    breaks an exhaustive match main just added, however many files name it. Any
    other name counts only while it is rare, which is what drops std names a
    variant line or a call happens to carry (`Some`, `Option`) and generic
    method names (`new`, `fmt`).
    """
    names = {n for n in names if len(n) >= 3}
    types = [n for n in names if n[0].isupper()]
    defined = set()
    if types:
        found = grep_hits([rf"\b(struct|enum|trait|type|union)[[:space:]]+({'|'.join(types)})\b"], new, regex=True)
        defined = {m.split()[-1] for m in found}
    counts = grep_hits(sorted(names - defined), new, word=True)
    return defined | {n for n in names - defined if len(counts.get(n, ())) <= COMMON_FILES}


def readers(data_paths: list[str], new: str) -> dict[str, set[str] | None]:
    """{data path: Rust files naming it or its nearest named ancestor directory, or None if none does}."""
    chains = {}
    for d in data_paths:
        rel = PurePosixPath(d).relative_to("assets")
        parts = rel.parent.parts
        # The file itself, then data/en/monsters/core, data/en/monsters (never bare data/en).
        chains[d] = [str(rel)] + ["/".join(parts[:cut]) for cut in range(len(parts), 2, -1)]
    hits = grep_hits(sorted({n for chain in chains.values() for n in chain}), new)
    return {d: next((hits[n] for n in chain if n in hits), None) for d, chain in chains.items()}


def dataset(path: str) -> str:
    """The unit a whole-dataset invariant ranges over: a data directory, or a top-level data file alone.

    `assets/data/en/monsters/core/` is one dataset split over files, so two
    branches adding to different files there can still add up red. The files
    directly under `assets/data/en/` are unrelated datasets that share a folder.
    """
    parent = PurePosixPath(path).parent
    return f"{parent}/" if len(parent.parts) > 3 else path


def near(path: str, reader: str) -> bool:
    """`path` is `reader` or inside the module it heads (x.rs owns x/, mod.rs owns its directory)."""
    p = PurePosixPath(reader)
    module = p.parent if p.name == "mod.rs" else p.with_suffix("")
    return path == reader or path.startswith(f"{module}/")


def decide(old: str, new: str) -> tuple[int, str]:
    moved = changed(old, new)
    wide = [p for p in moved if BUILD_WIDE.match(p)]
    if wide:
        return 0, f"build-wide: main changed {wide[0]}"
    main_paths = [p for p in code_paths(moved, new) if not p.startswith(GENERATED)]
    if not main_paths:
        return 1, "docs-only: main moved only in documentation"

    if is_ancestor(new, "HEAD"):
        own_base = new  # already synced onto new main: the branch's own diff is HEAD over it
    elif is_ancestor(old, "HEAD"):
        own_base = old
    else:
        return 0, "unknown: the branch descends from neither base"
    task_paths = [p for p in changed(own_base, "HEAD") if not p.startswith(GENERATED)]
    if not task_paths:
        return 0, "unknown: the branch changes nothing over its base"

    shared = sorted(set(main_paths) & set(task_paths))
    if shared:
        return 0, f"same file: {shared[0]}"

    main_data = {dataset(p) for p in main_paths if p.startswith(DATA)}
    task_data = {dataset(p) for p in task_paths if p.startswith(DATA)}
    if main_data & task_data:
        return 0, f"same data: both changed {sorted(main_data & task_data)[0]}"

    loaders = readers(sorted({p for p in main_paths + task_paths if p.startswith(DATA)}), new)
    for data_side, code_side, who in ((task_paths, main_paths, "main"), (main_paths, task_paths, "the branch")):
        code = [p for p in code_side if p.endswith(".rs")]
        for d in sorted({p for p in data_side if p.startswith(DATA)}):
            found = loaders[d]
            if found is None:
                if code:
                    return 0, f"data reader: no Rust names {d}'s directory, and {who} changed Rust"
                continue
            hit = next((c for c in code for r in found if near(c, r)), None)
            if hit:
                return 0, f"data reader: {who} changed {hit}, which loads {d}"

    main_lines, main_headers = changed_lines(old, new, main_paths)
    task_lines, task_headers = changed_lines(own_base, "HEAD", task_paths)
    main_words = set(WORD.findall("\n".join(main_lines + main_headers)))
    task_words = set(WORD.findall("\n".join(task_lines + task_headers)))
    for defined, other, who in ((symbols(task_lines, task_headers), main_words, "main"),
                                (symbols(main_lines, main_headers), task_words, "the branch")):
        met = sorted(distinctive(defined & other, new))
        if met:
            return 0, f"symbol: {who} changed a line naming `{met[0]}`"
    return 1, "no interaction: main's advance shares no file, data directory, data reader or symbol with the branch"


def main() -> int:
    global RUST_ATTRS
    if len(sys.argv) != 3:
        print("usage: freshness_interaction.py <verified-base> <new-base>", file=sys.stderr)
        return 0
    old, new = sys.argv[1], sys.argv[2]
    attrs = Path(os.environ.get("TMPDIR", "/tmp")) / f"freshness-attrs-{os.getpid()}"
    try:
        attrs.write_text("*.rs diff=rust\n")
        RUST_ATTRS = str(attrs)
        code, why = decide(old, new)
    except (GitError, OSError) as exc:
        code, why = 0, f"unknown: git failed ({exc})"
    finally:
        attrs.unlink(missing_ok=True)
    print(f"freshness: {why}", file=sys.stderr)
    try:
        branch = subprocess.run(["git", "branch", "--show-current"], capture_output=True, text=True).stdout.strip()
        log = Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache")) / "paperclip-verify" / "freshness.log"
        with log.open("a") as f:
            f.write(f"{time.strftime('%Y-%m-%dT%H:%M:%S')} {branch or '-'} {old[:9]}..{new[:9]} {code} {why}\n")
    except OSError:
        pass
    return code


if __name__ == "__main__":
    sys.exit(main())
