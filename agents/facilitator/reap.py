"""Reap what finished tasks leave behind: worktrees, branches, cloud sessions, caches.

merge-sweep.py tears a task down when its PR merges, and mechanical.py deletes
remote branches already on main. Everything else a task leaves when it ends any
other way (cancelled, superseded, closed by hand, done before its PR existed)
stayed forever: local worktrees, local and remote branches, cloud-verify refs,
completed cloud sessions, verify cache files, and cloud watchers still waiting on
a verdict nobody will read. This module is the one place that clears them.

Every rule turns on the TASK being finished (`done` or `cancelled`), never on age
or process liveness alone, and nothing here touches a live task. What would lose
work is never deleted: a dirty worktree is reported and left, and a task branch
with commits found nowhere else is pushed to origin before its local copy goes.

    reap.py                 report what it would do (no writes)
    reap.py --act           act; capped per run unless --limit 0
    REAP_ACT=1              act when run from the Dispatcher's sweep
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import time
import urllib.error
import urllib.request
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path

HERE = Path(__file__).resolve().parent
CLOUD_SESSION = HERE.parent / "architect" / "cloud-session.sh"
REAP_VERIFY = HERE.parent / "architect" / "reap-verify.sh"
VERIFY_DIR = Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache")) / "paperclip-verify"

FINISHED = ("done", "cancelled")
TASK_ID = re.compile(r"\b([A-Z]+-\d+)\b")
#: An unmerged remote task branch is the last copy of abandoned work: kept this
#: long after the task finished, then deleted.
REMOTE_GRACE = float(os.environ.get("REAP_REMOTE_GRACE_SECONDS", 7 * 86400))
#: Verify cache files outlive the task by this long, for anyone reading its logs.
CACHE_GRACE = float(os.environ.get("REAP_CACHE_GRACE_SECONDS", 7 * 86400))
#: A finished task's watcher gets this long to deliver before it is stopped.
WATCH_GRACE = float(os.environ.get("REAP_WATCH_GRACE_SECONDS", 86400))
#: An operator worktree idle this long whose tip adds nothing to main is removed
#: without a merged PR. The idle check keeps a worktree just cut from main, which
#: also adds nothing, from being removed under the operator starting work in it.
OP_IDLE = float(os.environ.get("REAP_OP_IDLE_SECONDS", 86400))
#: Destructive actions per sweep. A worktree removal can take seconds and the
#: Dispatcher's run is bounded, so a backlog drains over several sweeps.
LIMIT = int(os.environ.get("REAP_LIMIT", 40))


def iso(stamp: str | None) -> float | None:
    return datetime.fromisoformat(stamp.replace("Z", "+00:00")).timestamp() if stamp else None


def finished_at(issue: dict | None) -> float | None:
    """When the task finished, or None while it is live (or unknown)."""
    if not issue or issue.get("status") not in FINISHED:
        return None
    return iso(issue.get("completedAt") or issue.get("cancelledAt") or issue.get("updatedAt"))


def task_of(ref: str) -> str | None:
    m = TASK_ID.search(ref)
    return m.group(1) if m else None


# --------------------------------------------------------------------------- facts


def run(*args: str, cwd: Path | None = None, timeout: int = 120) -> subprocess.CompletedProcess:
    return subprocess.run(list(args), cwd=cwd, capture_output=True, text=True, timeout=timeout)


def git(repo: Path, *args: str) -> subprocess.CompletedProcess:
    return run("git", "-C", str(repo), *args)


def ok(repo: Path, *args: str) -> bool:
    return git(repo, *args).returncode == 0


@dataclass
class Local:
    branch: str
    tip: str
    worktree: Path | None
    dirty: bool
    on_main: bool      # every patch is on origin/main
    on_origin: bool    # origin/<branch> contains the tip
    diverged: bool = False  # origin/<branch> exists but does not contain the tip


#: Files that mean a worktree is mid-operation: its branch is detached while it
#: runs, and the work in flight is in neither the branch nor the index.
IN_PROGRESS = ("rebase-merge", "rebase-apply", "MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD")


def in_progress(wt: Path) -> list[Path]:
    paths = git(wt, "rev-parse", "--git-path", *IN_PROGRESS).stdout.split()
    return [wt / p if not Path(p).is_absolute() else Path(p) for p in paths if (wt / p).exists()]


def worktrees(repo: Path) -> dict[str, Path]:
    """branch -> worktree path, the main checkout excluded.

    A worktree stopped mid-rebase is detached, so its branch is read from the
    rebase's own record; otherwise it would look like a branch with no worktree.
    """
    out, found, path = git(repo, "worktree", "list", "--porcelain").stdout, {}, None
    for line in out.splitlines():
        if line.startswith("worktree "):
            path = Path(line[9:])
        elif line.startswith("branch refs/heads/") and path and path != repo:
            found[line[len("branch refs/heads/"):]] = path
        elif line == "detached" and path and path != repo and path.exists():
            for p in in_progress(path):
                head = p / "head-name"
                if head.is_file() and head.read_text().startswith("refs/heads/"):
                    found[head.read_text().strip()[len("refs/heads/"):]] = path
    return found


def adds_nothing(repo: Path, tip: str) -> bool:
    """Whether merging `tip` into origin/main leaves main's tree unchanged.

    Decided by a merge, not by patch ids: work that landed squashed, rebased or
    ported under other commits still merges to main's own tree.
    """
    if ok(repo, "merge-base", "--is-ancestor", tip, "origin/main"):
        return True
    merged = git(repo, "merge-tree", "--write-tree", "origin/main", tip)
    return merged.returncode == 0 and \
        merged.stdout.split("\n", 1)[0].strip() == git(repo, "rev-parse", "origin/main^{tree}").stdout.strip()


def idle_for(wt: Path | None, now: float) -> float:
    """Seconds since the worktree's index last changed (checkout, add, commit, status)."""
    if not wt:
        return float("inf")
    index = Path(git(wt, "rev-parse", "--git-path", "index").stdout.strip())
    index = index if index.is_absolute() else wt / index
    return now - index.stat().st_mtime if index.exists() else float("inf")


def op_root(repo: Path) -> Path:
    """Where operator worktrees live: a sibling `<repo>-op/` directory."""
    return repo.parent / f"{repo.name}-op"


def detached_op(repo: Path) -> list[tuple[Path, str]]:
    """(path, HEAD) of detached worktrees under the operator root."""
    root, found, path, head = op_root(repo), [], None, None
    for line in git(repo, "worktree", "list", "--porcelain").stdout.splitlines() + [""]:
        if line.startswith("worktree "):
            path = Path(line[9:])
        elif line.startswith("HEAD "):
            head = line[5:]
        elif line == "detached" and path and root in path.parents and path.exists():
            found.append((path, head))
    return found


def locals_(repo: Path, patterns: list[str]) -> list[Local]:
    trees = worktrees(repo)
    out = git(repo, "for-each-ref", "--format=%(refname:short)\t%(objectname)",
              *[f"refs/heads/{p}" for p in patterns]).stdout
    found = []
    for line in out.splitlines():
        branch, _, tip = line.partition("\t")
        wt = trees.get(branch)
        dirty = bool(wt and wt.exists() and (git(wt, "status", "--porcelain").stdout.strip() or in_progress(wt)))
        # `git cherry`, so patches that landed under other SHAs (squash, rebase) count.
        on_main = "+ " not in git(repo, "cherry", "origin/main", branch).stdout
        remote = ok(repo, "rev-parse", "--verify", "-q", f"refs/remotes/origin/{branch}")
        on_origin = remote and ok(repo, "merge-base", "--is-ancestor", tip, f"refs/remotes/origin/{branch}")
        found.append(Local(branch, tip, wt, dirty, on_main, on_origin, remote and not on_origin))
    return found


def remotes(repo: Path, patterns: list[str]) -> list[tuple[str, str]]:
    out = git(repo, "for-each-ref", "--format=%(refname:lstrip=3)\t%(objectname)",
              *[f"refs/remotes/origin/{p}" for p in patterns]).stdout
    return [tuple(line.split("\t")) for line in out.splitlines() if "\t" in line]


def pr_states(repo: Path) -> dict[str, list[dict]]:
    """head branch -> PRs, from the repo's own origin (never the gh default repo)."""
    url = git(repo, "remote", "get-url", "origin").stdout.strip()
    slug = re.sub(r"(\.git)?$", "", re.sub(r"^.*github\.com[:/]", "", url))
    r = run("gh", "pr", "list", "--repo", slug, "--state", "all", "--limit", "5000",
            "--json", "headRefName,state,headRefOid", timeout=180)
    if r.returncode != 0:
        raise RuntimeError(f"gh pr list {slug}: {r.stderr.strip()}")
    found: dict[str, list[dict]] = {}
    for pr in json.loads(r.stdout):
        found.setdefault(pr["headRefName"], []).append(pr)
    return found


# --------------------------------------------------------------------------- decisions


@dataclass
class Action:
    kind: str   # push | remove-worktree | delete-local | delete-remote | delete-session | stop-watch | delete-cache
    target: str
    why: str
    repo: Path | None = None
    task: str | None = None


def plan_task_locals(repo: Path, branches: list[Local], tasks: dict, prs: dict,
                     now: float) -> tuple[list[Action], list[str]]:
    """task/* and cloud-verify/* local branches (and worktrees) of finished tasks."""
    acts, kept = [], []
    for b in branches:
        ident = task_of(b.branch)
        at = finished_at(tasks.get(ident))
        if at is None:
            continue
        if any(p["state"] == "OPEN" for p in prs.get(b.branch, [])):
            kept.append(f"{b.branch}: task {tasks[ident]['status']} but PR still open")
            continue
        if b.dirty:
            kept.append(f"{b.branch}: uncommitted changes or an unfinished rebase/merge in {b.worktree}")
            continue
        cloud = b.branch.startswith("cloud-verify/")
        if not cloud and not b.on_main and not b.on_origin and now - at < REMOTE_GRACE:
            # The only copy of this work: archive it on origin for what is left of
            # REMOTE_GRACE. Past it, plan_task_remotes would delete the push anyway.
            if b.diverged:
                # Overwriting origin's copy would lose the commits only it has; the
                # local tip is archived beside it and expires with it.
                acts.append(Action("push", f"{b.branch}\t{b.branch}-local-{b.tip[:9]}",
                                   "diverged from origin; archived beside it", repo, ident))
            else:
                acts.append(Action("push", b.branch, "commits exist only on this disk", repo, ident))
        if b.worktree:
            acts.append(Action("remove-worktree", str(b.worktree), f"task {tasks[ident]['status']}", repo, ident))
        acts.append(Action("delete-local", b.branch, f"task {tasks[ident]['status']}", repo, ident))
    return acts, kept


def plan_task_remotes(repo: Path, branches: list[tuple[str, str]], tasks: dict, prs: dict, now: float) -> list[Action]:
    """cloud-verify/* once the task finished; task/* REMOTE_GRACE after it finished."""
    acts = []
    for branch, tip in branches:
        ident = task_of(branch)
        at = finished_at(tasks.get(ident))
        if at is None or any(p["state"] == "OPEN" for p in prs.get(branch, [])):
            continue
        if branch.startswith("cloud-verify/") or now - at >= REMOTE_GRACE:
            acts.append(Action("delete-remote", f"{branch}\t{tip}", f"task {tasks[ident]['status']}", repo, ident))
    return acts


def plan_op(repo: Path, branches: list[Local], prs: dict, noop: set[str] = frozenset()) -> tuple[list[Action], list[str]]:
    """op/* once its PR merged, its tree is clean, and every patch is on main.

    `noop` names op/* branches that need no PR: idle, and their tip adds nothing to
    main. An unmerged op/* branch that adds something is the operator's, and left.
    """
    acts, kept = [], []
    for b in branches:
        if any(p["state"] == "OPEN" for p in prs.get(b.branch, [])):
            continue
        if b.branch in noop and not b.dirty:
            if b.worktree:
                acts.append(Action("remove-worktree", str(b.worktree), "adds nothing to main", repo))
            acts.append(Action("delete-local", b.branch, "adds nothing to main", repo))
            if b.on_origin:
                acts.append(Action("delete-remote", f"{b.branch}\t{b.tip}", "adds nothing to main", repo))
            continue
        merged = [p for p in prs.get(b.branch, []) if p["state"] == "MERGED"]
        if not merged:
            continue
        if b.dirty:
            kept.append(f"{b.branch}: merged but has uncommitted changes in {b.worktree}")
            continue
        if not (b.on_main or any(p["headRefOid"] == b.tip for p in merged)):
            kept.append(f"{b.branch}: merged, but has commits after the merged head")
            continue
        if b.worktree:
            acts.append(Action("remove-worktree", str(b.worktree), "PR merged", repo))
        acts.append(Action("delete-local", b.branch, "PR merged", repo))
        if b.on_origin:
            acts.append(Action("delete-remote", f"{b.branch}\t{b.tip}", "PR merged", repo))
    return acts, kept


def plan_sessions(sessions: list[dict], tasks: dict) -> list[Action]:
    """Completed cloud sessions the pipeline started for a finished task."""
    acts = []
    for s in sessions:
        if s.get("status_bucket") != "completed":
            continue
        sources = (s.get("session_context") or {}).get("sources") or []
        revs = [src.get("revision") or "" for src in sources]
        ident = next((task_of(r) for r in revs if r.startswith("task/")), None)
        if ident and finished_at(tasks.get(ident)) is not None:
            acts.append(Action("delete-session", s["id"], f"completed; task {tasks[ident]['status']}", task=ident))
    return acts


def plan_cache(names: list[str], tasks: dict, now: float) -> list[Action]:
    acts = []
    for name in names:
        ident = name.split(".", 1)[0]
        at = finished_at(tasks.get(ident))
        if at is not None and now - at >= CACHE_GRACE:
            acts.append(Action("delete-cache", name, f"task finished {int((now - at) // 86400)}d ago", task=ident))
    return acts


def plan_watchers(units: list[str], tasks: dict, now: float) -> list[Action]:
    acts = []
    for unit in units:
        ident = task_of(unit)
        at = finished_at(tasks.get(ident))
        if at is not None and now - at >= WATCH_GRACE:
            acts.append(Action("stop-watch", unit, f"task {tasks[ident]['status']}", task=ident))
    return acts


# --------------------------------------------------------------------------- I/O


def tasks_by_id(base: str, company: str) -> dict[str, dict]:
    found = {}
    for status in ("done,cancelled", "backlog,todo,in_progress,in_review,blocked"):
        with urllib.request.urlopen(f"{base}/api/companies/{company}/issues?status={status}", timeout=120) as r:
            for issue in json.load(r):
                found[issue["identifier"]] = issue
    return found


def cloud_sessions() -> list[dict]:
    """Every session on the account, all pages; empty when the API cannot be read."""
    r = run(str(CLOUD_SESSION), "LIST", "")
    try:
        return json.loads(r.stdout) if r.returncode == 0 else []
    except ValueError:
        return []


def watcher_units() -> list[str]:
    r = run("systemctl", "--user", "list-units", "--plain", "--no-legend", "cloudwatch-*")
    return [line.split()[0] for line in r.stdout.splitlines() if line.strip()]


#: Where train-gate.sh builds a merged tree, one `wt-<tree>` per run. It removes
#: its own tree on exit, so one that survives is a run that was interrupted.
GATE_DIR = VERIFY_DIR / "train-gate"
#: A gate tree idle this long is a leftover; a live gate run touches its index.
GATE_IDLE = float(os.environ.get("REAP_GATE_IDLE_SECONDS", 86400))


def in_use(path: Path) -> list[int]:
    """Pids whose working directory or command line is inside `path`.

    Read at the moment of removal, never from an earlier scan: a build can start
    in a tree between the plan and the delete, and removing a tree a compiler is
    writing into fails that build as if its code were red.
    """
    root, pids = str(path.resolve()), []
    for proc in Path("/proc").iterdir():
        if not proc.name.isdigit():
            continue
        try:
            cwd = os.readlink(proc / "cwd")
            cmd = (proc / "cmdline").read_bytes().replace(b"\0", b" ").decode(errors="replace")
        except OSError:
            continue
        if cwd == root or cwd.startswith(root + "/") or root + "/" in cmd or cmd.rstrip().endswith(root):
            pids.append(int(proc.name))
    return pids


def gate_trees(repo: Path) -> list[Path]:
    """Leftover train-gate worktrees registered on this repo."""
    out = git(repo, "worktree", "list", "--porcelain").stdout
    return [Path(line[9:]) for line in out.splitlines()
            if line.startswith("worktree ") and Path(line[9:]).parent == GATE_DIR
            and Path(line[9:]).name.startswith("wt-")]


def live_builds() -> set[str]:
    """Task ids with a verify build running (reap-verify.sh --list)."""
    if not REAP_VERIFY.exists():
        return set()
    return {line.split()[0] for line in run(str(REAP_VERIFY), "--list").stdout.splitlines() if line.strip()}


def execute(a: Action, act: bool, building: set[str]) -> str:
    line = f"{a.kind:16} {a.target.split(chr(9))[0]}  ({a.why})"
    if not act:
        return "DRY " + line
    if a.kind == "push":
        src, _, dst = a.target.partition("\t")
        r = git(a.repo, "push", "--quiet", "--no-verify", "origin", f"{src}:refs/heads/{dst or src}")
    elif a.kind == "remove-worktree":
        # A build still compiling this tree would rebuild a deleted directory. Only
        # a live one is reaped: reap-verify writes a sentinel even when none runs.
        if a.task in building:
            reason = "parent-cancelled" if "cancelled" in a.why else "verify-done"
            if run(str(REAP_VERIFY), a.task, reason).returncode != 0:
                return f"SKIP {line}: verify build not reaped"
        busy = in_use(Path(a.target))
        if busy:
            return f"SKIP {line}: in use by pid {', '.join(map(str, busy[:5]))}"
        r = git(a.repo, "worktree", "remove", a.target)
    elif a.kind == "delete-local":
        r = git(a.repo, "branch", "-D", a.target)
    elif a.kind == "delete-remote":
        branch, tip = a.target.split("\t")
        # The lease refuses the delete if the branch moved since it was read.
        r = git(a.repo, "push", "--quiet", f"--force-with-lease={branch}:{tip}", "origin", f":refs/heads/{branch}")
    elif a.kind == "delete-session":
        r = run(str(CLOUD_SESSION), "DELETE", a.target)
    elif a.kind == "stop-watch":
        r = run("systemctl", "--user", "stop", a.target)
    elif a.kind == "delete-cache":
        (VERIFY_DIR / a.target).unlink(missing_ok=True)
        return line
    else:
        raise ValueError(a.kind)
    return line if r.returncode == 0 else f"FAIL {line}: {(r.stderr or r.stdout).strip()[-200:]}"


def ordered(acts: list[Action]) -> list[list[Action]]:
    """Group a branch's actions so a cap never splits push from delete."""
    groups: dict[tuple, list[Action]] = {}
    for a in acts:
        key = (a.kind, a.target) if a.kind in ("delete-session", "stop-watch", "delete-cache") \
            else (str(a.repo), a.task or a.target.split("\t")[0].split("/")[-1])
        groups.setdefault(key, []).append(a)
    return list(groups.values())


def reap(project: Path, paperclip: Path, base: str, company: str, act: bool, limit: int,
         now: float | None = None) -> dict:
    now = now or time.time()
    tasks = tasks_by_id(base, company)
    acts: list[Action] = []
    kept: list[str] = []
    for repo, task_repo in ((project, True), (paperclip, False)):
        git(repo, "fetch", "--quiet", "--prune", "origin")
        git(repo, "worktree", "prune")
        prs = pr_states(repo)
        if task_repo:
            a, k = plan_task_locals(repo, locals_(repo, ["task/", "cloud-verify/"]), tasks, prs, now)
            acts += a
            kept += k
            acts += plan_task_remotes(repo, remotes(repo, ["task/", "cloud-verify/"]), tasks, prs, now)
        ops = locals_(repo, ["op/"])
        noop = {b.branch for b in ops if idle_for(b.worktree, now) >= OP_IDLE and adds_nothing(repo, b.tip)}
        a, k = plan_op(repo, ops, prs, noop)
        acts += a
        kept += k
        if task_repo:
            for path in gate_trees(repo):
                if path.exists() and idle_for(path, now) >= GATE_IDLE:
                    acts.append(Action("remove-worktree", str(path), "train-gate run left it behind", repo))
        for path, head in detached_op(repo):
            if idle_for(path, now) >= OP_IDLE and not git(path, "status", "--porcelain").stdout.strip() \
                    and not in_progress(path) and adds_nothing(repo, head):
                acts.append(Action("remove-worktree", str(path), "detached; adds nothing to main", repo))
    acts += plan_sessions(cloud_sessions(), tasks)
    acts += plan_watchers(watcher_units(), tasks, now)
    if VERIFY_DIR.is_dir():
        acts += plan_cache(sorted(p.name for p in VERIFY_DIR.iterdir() if p.is_file()), tasks, now)

    building = live_builds() if act else set()
    done, deferred = [], 0
    for group in ordered(acts):
        if limit and act and len(done) >= limit:
            deferred += len(group)
            continue
        for a in group:
            line = execute(a, act, building)
            done.append(line)
            if line.startswith(("SKIP", "FAIL")):
                break  # never delete a branch whose push or worktree removal did not happen
    return {"at": now, "acted": act, "actions": done, "deferred": deferred, "kept": kept}


def main() -> int:
    import argparse

    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--act", action="store_true", help="delete; without it, only report")
    parser.add_argument("--limit", type=int, default=LIMIT, help="destructive actions per run; 0 = no cap")
    args = parser.parse_args()
    report = reap(Path(os.environ["PAPERCLIP_PROJECT"]), HERE.parent.parent,
                  os.environ.get("PAPERCLIP_API_URL", "http://localhost:3100").rstrip("/"),
                  os.environ["PAPERCLIP_COMPANY_ID"], args.act, args.limit)
    for line in report["actions"]:
        print(line)
    for line in report["kept"]:
        print(f"KEPT {line}")
    print(f"{len(report['actions'])} action(s), {report['deferred']} deferred, {len(report['kept'])} kept")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
