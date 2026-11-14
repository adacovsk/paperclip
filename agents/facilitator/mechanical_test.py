"""Decision tests for mechanical.py.  Run: python3 -m unittest agents/facilitator/mechanical_test.py"""

import importlib.util
import os
import subprocess
import sys
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path

_spec = importlib.util.spec_from_file_location("mechanical", Path(__file__).with_name("mechanical.py"))
m = importlib.util.module_from_spec(_spec)
sys.modules["mechanical"] = m
_spec.loader.exec_module(m)

NOW = datetime(2026, 10, 18, 12, tzinfo=timezone.utc).timestamp()
HOUR = 3600


def iso(hours_ago: float) -> str:
    return datetime.fromtimestamp(NOW - hours_ago * HOUR, timezone.utc).isoformat().replace("+00:00", "Z")


def task(ident, title="Verify: X-1 something", status="in_review", hours_ago=3, agent="architect", **extra):
    return {"id": ident, "identifier": ident, "title": title, "status": status, "assigneeAgentId": agent,
            "updatedAt": iso(hours_ago), "activeRun": None, "executionRunId": None, **extra}


def stalled(issues, runs=(), paused=(), skip=None, quiet=None, closed=None):
    return [i["identifier"] for i in m.missed_wakes(issues, list(runs), set(paused), skip, NOW, quiet, closed)]


class MissedWakes(unittest.TestCase):
    def test_an_assigned_stage_with_no_run_past_the_threshold_is_stalled(self):
        self.assertEqual(stalled([task("A")]), ["A"])

    def test_a_recent_stage_is_not_yet_stalled(self):
        self.assertEqual(stalled([task("A", hours_ago=1)]), [])

    def test_a_worker_parent_in_review_is_waiting_on_its_children(self):
        self.assertEqual(stalled([task("A", title="§4.1 Author a thing", agent="worker")]), [])

    def test_an_architect_held_parent_in_review_is_owed_a_run(self):
        parent = task("A", title="§4.1 Author a thing", agent="architect")
        self.assertEqual(m.missed_wakes([parent], [], set(), None, NOW, parent_owed=frozenset({"architect"})), [parent])

    def test_a_worker_parent_is_still_waiting_when_architect_parents_are_owed(self):
        parent = task("A", title="§4.1 Author a thing", agent="worker")
        self.assertEqual(m.missed_wakes([parent], [], set(), None, NOW, parent_owed=frozenset({"architect"})), [])

    def test_an_architect_held_parent_with_its_build_out_is_not_a_stall(self):
        parent = task("A", title="§4.1 Author a thing", agent="architect")
        self.assertEqual(m.missed_wakes([parent], [], set(), None, NOW, lambda i: None,
                                        parent_owed=frozenset({"architect"})), [])

    def test_an_in_progress_task_its_agent_took_is_owed_a_run(self):
        self.assertEqual(stalled([task("A", title="§4.1 Author a thing", status="in_progress")]), ["A"])

    def test_a_live_run_on_the_issue_is_not_a_stall(self):
        self.assertEqual(stalled([task("A")], runs=[{"id": "r", "issueId": "A", "status": "queued"}]), [])

    def test_an_execution_run_that_is_still_live_is_not_a_stall(self):
        self.assertEqual(stalled([task("A", executionRunId="r")], runs=[{"id": "r", "status": "running"}]), [])

    def test_an_execution_run_that_has_ended_is_a_stall(self):
        self.assertEqual(stalled([task("A", executionRunId="dead")]), ["A"])

    def test_the_sweeping_agent_and_paused_agents_are_skipped(self):
        self.assertEqual(stalled([task("A", agent="dispatcher"), task("B", agent="off")],
                                 paused={"off"}, skip="dispatcher"), [])

    def test_unassigned_and_blocked_tasks_are_not_owed_a_wake(self):
        self.assertEqual(stalled([task("A", agent=None), task("B", status="blocked")]), [])

    def test_work_still_running_off_the_board_is_not_a_stall(self):
        self.assertEqual(stalled([task("A")], quiet=lambda i: None), [])

    def test_a_recent_off_board_event_restarts_the_clock(self):
        self.assertEqual(stalled([task("A", hours_ago=5)], quiet=lambda i: NOW - 0.5 * HOUR), [])

    def test_a_stage_under_a_closed_parent_is_not_owed_a_wake(self):
        closed = lambda i: i.get("parentId") == "merged"
        self.assertEqual(stalled([task("A", parentId="merged"), task("B", parentId="open")], closed=closed), ["B"])

    def test_closed_parent_check_reads_only_parents_not_listed_open(self):
        class Api:
            reads = []

            def get(self, path):
                self.reads.append(path)
                return {"status": "done"}
        api = Api()
        check = m.closed_parent_check(api, [{"id": "p-open"}])
        self.assertFalse(check({"parentId": "p-open"}))
        self.assertFalse(check({}))
        self.assertTrue(check({"parentId": "p-done"}))
        self.assertEqual(api.reads, ["/issues/p-done"])

    def test_oldest_stall_first(self):
        self.assertEqual(stalled([task("new", hours_ago=3), task("old", hours_ago=30)]), ["old", "new"])


class PlanToggles(unittest.TestCase):
    def test_a_first_stall_is_toggled_and_counted(self):
        due, failing, hist = m.plan_toggles([task("A")], {}, NOW)
        self.assertEqual([i["id"] for i in due], ["A"])
        self.assertEqual(failing, [])
        self.assertEqual(hist["A"]["count"], 1)

    def test_a_recent_toggle_is_not_repeated(self):
        due, _, hist = m.plan_toggles([task("A")], {"A": {"at": NOW - HOUR, "count": 1}}, NOW)
        self.assertEqual(due, [])
        self.assertEqual(hist["A"]["count"], 1)

    def test_toggles_that_keep_not_taking_escalate(self):
        _, failing, _ = m.plan_toggles([task("A")], {"A": {"at": NOW - HOUR, "count": m.TOGGLE_ESCALATE}}, NOW)
        self.assertEqual([i["id"] for i in failing], ["A"])

    def test_a_task_that_moved_forgets_its_count(self):
        _, _, hist = m.plan_toggles([], {"A": {"at": NOW - HOUR, "count": 2}}, NOW)
        self.assertEqual(hist, {})

    def test_toggles_per_sweep_are_capped(self):
        many = [task(f"T{n}") for n in range(m.TOGGLE_CAP + 5)]
        due, _, _ = m.plan_toggles(many, {}, NOW)
        self.assertEqual(len(due), m.TOGGLE_CAP)


class Wedged(unittest.TestCase):
    def run_(self, agent, status, minutes_ago):
        return {"id": f"{agent}{status}{minutes_ago}", "agentId": agent, "agentName": agent, "status": status,
                "createdAt": iso(minutes_ago / 60)}

    def test_queued_with_none_running_past_the_threshold_is_wedged(self):
        found = m.wedged([self.run_("W", "queued", 40), self.run_("W", "queued", 5)], NOW)
        self.assertEqual([(a["agentName"], a["queued"]) for a in found], [("W", 2)])

    def test_an_agent_at_its_cap_is_not_wedged(self):
        self.assertEqual(m.wedged([self.run_("W", "queued", 40), self.run_("W", "running", 40)], NOW), [])

    def test_a_fresh_queue_is_not_wedged(self):
        self.assertEqual(m.wedged([self.run_("W", "queued", 5)], NOW), [])


class FakeApi:

    def __init__(self):
        self.calls = []

    def write(self, method, path, body, what):
        self.calls.append((method, path, body))
        return {"id": "new"} if method == "POST" and path.endswith("/issues") else None

    def set_status(self, issue, body, comment, what):
        self.calls.append(("STATUS", issue["identifier"], body, comment))


class ReadApi(FakeApi):
    def __init__(self, issues):
        super().__init__()
        self.issues_by_id = issues

    def get(self, path):
        return self.issues_by_id.get(path.rsplit("/", 1)[-1])


class FinishToggles(unittest.TestCase):
    ENTRY = {"agent": "architect", "identifier": "X-1"}

    def finish(self, issue):
        api, pending = ReadApi({"i1": issue}), {"i1": dict(self.ENTRY)}
        return m.finish_toggles(api, pending), api.calls, pending

    def test_a_task_left_unassigned_is_given_back_to_its_agent(self):
        finished, calls, pending = self.finish({"status": "in_review", "assigneeAgentId": None})
        self.assertEqual((finished, pending), (["X-1"], {}))
        self.assertEqual(calls[0][:2], ("PATCH", "/issues/i1"))
        self.assertEqual(calls[0][2]["assigneeAgentId"], "architect")

    def test_a_task_someone_already_reassigned_is_left_as_it_is(self):
        self.assertEqual(self.finish({"status": "in_review", "assigneeAgentId": "worker"}), ([], [], {}))
        self.assertEqual(self.finish({"status": "todo", "assigneeAgentId": None, "assigneeUserId": "u"}), ([], [], {}))

    def test_a_closed_or_missing_task_is_dropped_from_the_journal(self):
        self.assertEqual(self.finish({"status": "cancelled", "assigneeAgentId": None}), ([], [], {}))
        self.assertEqual(self.finish(None), ([], [], {}))

    def test_a_failed_read_keeps_the_entry_for_the_next_sweep(self):
        class Down(FakeApi):
            def get(self, path):
                raise OSError("unreachable")
        pending = {"i1": dict(self.ENTRY)}
        with self.assertRaises(OSError):
            m.finish_toggles(Down(), pending)
        self.assertEqual(pending, {"i1": self.ENTRY})


class FileWedges(unittest.TestCase):
    W = {"agentName": "Worker", "queued": 3, "oldest": "2026-10-18T11:00:00Z"}

    def filing(self, status):
        return {"identifier": "X-1", "title": f"{m.WEDGE_TITLE}Worker holds queued runs, none running",
                "status": status, "createdAt": "2026-10-01T00:00:00Z"}

    def test_a_first_wedge_is_filed_held_for_the_operator(self):
        api = FakeApi()
        m.file_wedges(api, [self.W], [])
        self.assertTrue(api.calls[0][2]["title"].startswith("[class:wedged-dispatcher] Worker "))
        self.assertEqual(api.calls[0][2]["status"], "blocked")
        self.assertEqual(api.calls[1][2]["hold"]["kind"], "operator")
        self.assertTrue(api.calls[1][2]["comment"].startswith("Held: operator"))

    def test_an_open_filing_is_not_filed_again(self):
        api = FakeApi()
        self.assertEqual(m.file_wedges(api, [self.W], [self.filing("blocked")]), [])
        self.assertEqual(api.calls, [])

    def test_a_closed_filing_is_reopened_as_a_recurrence(self):
        api = FakeApi()
        m.file_wedges(api, [self.W], [self.filing("done")])
        kind, ident, body, comment = api.calls[0]
        self.assertEqual((kind, ident, body["hold"]["kind"]), ("STATUS", "X-1", "operator"))
        self.assertTrue(comment.startswith("Held: operator") and "Recurrence:" in comment)


def firing(ident, routine="r1", status="todo", hours_ago=3, created_hours_ago=None, agent="tester", **extra):
    return task(ident, title="Nightly", status=status, hours_ago=hours_ago, agent=agent,
                originKind=m.ROUTINE_ORIGIN, originId=routine,
                createdAt=iso(hours_ago if created_hours_ago is None else created_hours_ago), **extra)


def routines(issues, runs=(), paused=(), skip=None, fired=None):
    refire, superseded = m.missed_routines(issues, list(runs), set(paused), skip, NOW, fired)
    return [i["identifier"] for i in refire], [(old["identifier"], by) for old, by in superseded]


LATER = "a later firing that has since closed"


def fired(hours_ago, issue_id="other", routine="r1"):
    return {routine: {"at": NOW - hours_ago * HOUR, "issueId": issue_id}}


class MissedRoutines(unittest.TestCase):
    def test_a_firing_that_never_got_a_run_is_refired(self):
        self.assertEqual(routines([firing("A")]), (["A"], []))

    def test_a_firing_its_agent_took_and_then_lost_is_refired(self):
        self.assertEqual(routines([firing("A", status="in_progress", executionRunId="dead")]), (["A"], []))

    def test_a_fresh_firing_is_given_time_to_start(self):
        self.assertEqual(routines([firing("A", hours_ago=1)]), ([], []))

    def test_a_running_firing_is_left_alone(self):
        self.assertEqual(routines([firing("A")], runs=[{"id": "r", "issueId": "A", "status": "running"}]), ([], []))

    def test_only_the_newest_firing_is_refired_and_the_rest_are_superseded(self):
        got = routines([firing("old", hours_ago=50), firing("mid", hours_ago=26), firing("new", hours_ago=3)])
        self.assertEqual(got, (["new"], [("old", "new"), ("mid", "new")]))

    def test_a_stalled_firing_behind_a_running_one_is_superseded_not_refired(self):
        got = routines([firing("old", hours_ago=26), firing("new", hours_ago=1)],
                       runs=[{"id": "r", "issueId": "new", "status": "running"}])
        self.assertEqual(got, ([], [("old", "new")]))

    def test_each_routine_keeps_its_own_newest(self):
        got = routines([firing("A", routine="r1"), firing("B", routine="r2", hours_ago=4)])
        self.assertEqual(got, (["B", "A"], []))

    def test_ordinary_tasks_and_closed_firings_are_not_firings(self):
        plain = task("P", status="todo")
        self.assertEqual(routines([plain, firing("A", status="done"), firing("B", status="cancelled")]), ([], []))

    def test_paused_agents_are_skipped(self):
        self.assertEqual(routines([firing("old", agent="off", hours_ago=30), firing("new", agent="off")],
                                  paused={"off"}), ([], []))

    def test_the_sweeping_agents_own_firing_is_never_refired(self):
        self.assertEqual(routines([firing("A", agent="dispatcher")], skip="dispatcher"), ([], []))

    def test_the_sweeping_agents_abandoned_firings_are_superseded(self):
        got = routines([firing("old", agent="dispatcher", hours_ago=30), firing("new", agent="dispatcher", hours_ago=1)],
                       runs=[{"id": "r", "issueId": "new", "status": "running"}], skip="dispatcher")
        self.assertEqual(got, ([], [("old", "new")]))

    def test_an_unrun_firing_is_superseded_by_a_later_one_that_already_closed(self):
        self.assertEqual(routines([firing("A", hours_ago=30)], fired=fired(2)), ([], [("A", LATER)]))

    def test_a_run_that_filed_no_task_of_its_own_replaces_nothing(self):
        self.assertEqual(routines([firing("A", hours_ago=30)], fired=fired(2, issue_id=None)), (["A"], []))
        self.assertEqual(routines([firing("A", hours_ago=30)], fired=fired(2, issue_id="A")), (["A"], []))

    def test_the_routines_own_run_for_this_firing_replaces_nothing(self):
        self.assertEqual(routines([firing("A", hours_ago=30)], fired=fired(31)), (["A"], []))

    def test_a_parked_firing_is_never_refired(self):
        self.assertEqual(routines([firing("A", status="in_review", hours_ago=100),
                                   firing("B", routine="r2", status="blocked", hours_ago=100)]), ([], []))

    def test_a_long_parked_firing_is_superseded_once_the_routine_fires_again(self):
        got = routines([firing("A", status="in_review", hours_ago=100),
                        firing("B", routine="r2", status="blocked", hours_ago=100)],
                       fired={**fired(2), **fired(2, routine="r2")})
        self.assertEqual(got, ([], [("A", LATER), ("B", LATER)]))

    def test_a_recently_parked_firing_is_left_to_whoever_parked_it(self):
        self.assertEqual(routines([firing("A", status="blocked", hours_ago=30)], fired=fired(2)), ([], []))
        self.assertEqual(routines([firing("A", status="blocked", hours_ago=30), firing("B", hours_ago=1)]), ([], []))

    def test_last_fired_is_read_from_the_routine_list(self):
        got = m.routine_last_fired([{"id": "r1", "lastRun": {"triggeredAt": iso(2), "linkedIssueId": "X"}},
                                    {"id": "r2", "lastRun": None}])
        self.assertEqual(got, {"r1": {"at": NOW - 2 * HOUR, "issueId": "X"}})

    def test_superseding_cancels_with_the_replacement_named(self):
        api = FakeApi()
        m.supersede(api, firing("old"), "new")
        kind, ident, body, comment = api.calls[0]
        self.assertEqual((kind, ident, body), ("STATUS", "old", {"status": "cancelled"}))
        self.assertIn("Superseded by new", comment)


def run(agent, status, hours_ago, error=None, finished=True):
    return {"agentId": agent, "status": status, "errorCode": error, "startedAt": iso(hours_ago),
            "createdAt": iso(hours_ago), "finishedAt": iso(hours_ago) if finished else None}


class RunDigest(unittest.TestCase):
    NAMES = {"a": "Architect", "w": "Worker"}

    def test_runs_are_counted_per_agent_by_outcome(self):
        got = m.run_digest([run("a", "succeeded", 1), run("a", "failed", 2, m.QUOTA_ERROR),
                            run("a", "failed", 3, m.QUOTA_ERROR), run("w", "running", 0.1, finished=False)],
                           self.NAMES, NOW)
        self.assertEqual(got["byAgent"], {"Architect": {"succeeded": 1, f"failed:{m.QUOTA_ERROR}": 2},
                                          "Worker": {"running": 1}})

    def test_runs_older_than_the_window_are_not_counted(self):
        got = m.run_digest([run("a", "succeeded", 30)], self.NAMES, NOW)
        self.assertEqual((got["byAgent"], got["coveredHours"]), ({}, 24.0))

    def test_a_fetch_that_stops_short_of_the_window_says_how_far_it_reached(self):
        self.assertEqual(m.run_digest([run("a", "failed", 2), run("a", "failed", 5)], self.NAMES, NOW)["coveredHours"], 5.0)

    def test_quota_is_out_for_an_agent_whose_newest_finished_run_died_on_it(self):
        got = m.run_digest([run("a", "failed", 1, m.QUOTA_ERROR), run("a", "succeeded", 5),
                            run("w", "succeeded", 1), run("w", "failed", 5, m.QUOTA_ERROR)], self.NAMES, NOW)
        self.assertEqual(got["quotaOut"], ["Architect"])

    def test_a_run_still_going_does_not_decide_quota(self):
        got = m.run_digest([run("a", "running", 0.1, finished=False), run("a", "failed", 1, m.QUOTA_ERROR)],
                           self.NAMES, NOW)
        self.assertEqual(got["quotaOut"], ["Architect"])


def commit(oid, hours_ago, state=None, status_hours_ago=None, context=None):
    contexts = [] if state is None else [{"context": context or m.NIGHTLY_CONTEXT, "state": state,
                                          "createdAt": iso(hours_ago if status_hours_ago is None else status_hours_ago)}]
    return {"oid": oid, "committedDate": iso(hours_ago), "status": {"contexts": contexts} if contexts else None}


class Nightly(unittest.TestCase):
    def test_the_newest_status_is_read_with_the_commits_merged_since(self):
        got = m.read_nightly([commit("c3", 1), commit("c2", 5, "FAILURE", 4), commit("c1", 30, "SUCCESS")], NOW)
        self.assertEqual(got, {"sha": "c2", "state": "failure", "ageHours": 4.0, "commitsSince": 1, "stale": False})

    def test_a_status_older_than_the_cadence_allows_is_stale(self):
        self.assertTrue(m.read_nightly([commit("c2", 1), commit("c1", 60, "SUCCESS")], NOW)["stale"])

    def test_another_checks_status_is_not_the_nightly(self):
        got = m.read_nightly([commit("c1", 1, "SUCCESS", context="other/check"), commit("c0", 60)], NOW)
        self.assertEqual((got["sha"], got["stale"]), (None, True))

    def test_no_status_on_commits_reaching_past_the_threshold_is_stale(self):
        self.assertEqual(m.read_nightly([commit("c2", 1), commit("c1", 60)], NOW),
                         {"sha": None, "state": None, "searched": 2, "stale": True})

    def test_a_search_that_did_not_reach_the_threshold_decides_nothing(self):
        self.assertIsNone(m.read_nightly([commit("c2", 1), commit("c1", 5)], NOW)["stale"])
        self.assertIsNone(m.read_nightly([], NOW)["stale"])


class Branches(unittest.TestCase):
    def test_young_branches_and_open_pr_heads_are_never_candidates(self):
        rows = [("old", NOW - 48 * HOUR, "s1"), ("young", NOW - HOUR, "s2"), ("pr", NOW - 48 * HOUR, "s3")]
        self.assertEqual(m.deletable(rows, {"pr"}, NOW), [("old", "s1")])

    def test_on_main_tells_merged_and_squashed_from_unlanded_work(self):
        with tempfile.TemporaryDirectory() as tmp:
            origin, work = Path(tmp, "origin.git"), Path(tmp, "work")

            def g(*args, cwd=work):
                return subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True, text=True).stdout

            subprocess.run(["git", "init", "-q", "--bare", "-b", "main", str(origin)], check=True)
            subprocess.run(["git", "clone", "-q", str(origin), str(work)], check=True, capture_output=True)
            g("config", "user.email", "t@t"), g("config", "user.name", "t")
            g("checkout", "-q", "-b", "main")
            Path(work, "a").write_text("a\n"), g("add", "a"), g("commit", "-qm", "a")
            g("push", "-q", "origin", "main")
            # merged: a branch whose tip main already contains
            g("push", "-q", "origin", "main:refs/heads/merged")
            # squashed: the same change landed on main as a different commit
            g("checkout", "-q", "-b", "squashed")
            Path(work, "b").write_text("b\n"), g("add", "b"), g("commit", "-qm", "b on branch")
            g("push", "-q", "origin", "squashed")
            g("checkout", "-q", "main")
            Path(work, "b").write_text("b\n"), g("add", "b"), g("commit", "-qm", "b squashed")
            g("push", "-q", "origin", "main")
            # unlanded: work main does not have
            g("checkout", "-q", "-b", "unlanded")
            Path(work, "c").write_text("c\n"), g("add", "c"), g("commit", "-qm", "c")
            g("push", "-q", "origin", "unlanded")
            g("fetch", "-q", "origin")
            main = g("rev-parse", "origin/main").strip()
            tips = {b: sha for b, _, sha in m.remote_branches(work)}

            self.assertEqual(sorted(tips), ["merged", "squashed", "unlanded"])
            self.assertEqual(m.on_main(work, tips["merged"], main), "tip is on origin/main")
            self.assertEqual(m.on_main(work, tips["squashed"], main), "merging it into origin/main changes nothing")
            self.assertIsNone(m.on_main(work, tips["unlanded"], main))

            # Deletion is opt-in; with it on, only branches whose work is on main go.
            later = NOW + 365 * 24 * HOUR
            listed = m.merged_branches(work, set(), False, later)
            self.assertEqual(sorted((e["branch"], e["deleted"]) for e in listed),
                             [("merged", False), ("squashed", False)])
            os.environ["FACILITATOR_DELETE_BRANCHES"] = "1"
            try:
                m.merged_branches(work, set(), False, later)
            finally:
                del os.environ["FACILITATOR_DELETE_BRANCHES"]
            self.assertEqual(g("ls-remote", "--heads", "origin").count("refs/heads/"), 2)  # main, unlanded
            self.assertIn("refs/heads/unlanded", g("ls-remote", "--heads", "origin"))


class Stranded(unittest.TestCase):
    def test_only_old_unpushed_branches_with_unlanded_work_are_pushed(self):
        with tempfile.TemporaryDirectory() as tmp:
            origin, work = Path(tmp, "origin.git"), Path(tmp, "work")

            def g(*args):
                return subprocess.run(["git", *args], cwd=work, check=True, capture_output=True, text=True).stdout

            subprocess.run(["git", "init", "-q", "--bare", "-b", "main", str(origin)], check=True)
            subprocess.run(["git", "clone", "-q", str(origin), str(work)], check=True, capture_output=True)
            g("config", "user.email", "t@t"), g("config", "user.name", "t")
            g("checkout", "-q", "-b", "main")
            Path(work, "a").write_text("a\n"), g("add", "a"), g("commit", "-qm", "a")
            g("push", "-q", "origin", "main")
            for name in ("task/AA-1", "task/AA-2", "task/AA-3", "other"):
                g("checkout", "-q", "-b", name, "main")
                Path(work, name.replace("/", "_")).write_text("x\n"), g("add", "-A"), g("commit", "-qm", name)
            g("push", "-q", "origin", "task/AA-2")             # already has an origin copy
            g("branch", "-q", "-f", "task/AA-3", "main")       # nothing main lacks
            g("checkout", "-q", "main"), g("fetch", "-q", "origin")

            self.assertEqual(m.stranded_branches(work, False, NOW - 365 * 24 * HOUR), [])  # all too young
            self.assertEqual(m.stranded_branches(work, True, NOW + 365 * 24 * HOUR),
                             [{"branch": "task/AA-1", "ahead": 1, "pushed": True}])
            self.assertNotIn("task/AA-1", g("ls-remote", "--heads", "origin"))  # dry run pushed nothing
            m.stranded_branches(work, False, NOW + 365 * 24 * HOUR)
            heads = g("ls-remote", "--heads", "origin")
            self.assertIn("refs/heads/task/AA-1", heads)
            self.assertNotIn("refs/heads/other", heads)  # outside the task namespace

    def test_a_finished_tasks_branch_is_never_pushed(self):
        # reap.py deletes a finished task's remote branch REMOTE_GRACE after it
        # finished; pushing it back here would undo that every cycle.
        with tempfile.TemporaryDirectory() as tmp:
            origin, work = Path(tmp, "origin.git"), Path(tmp, "work")

            def g(*args):
                return subprocess.run(["git", *args], cwd=work, check=True, capture_output=True, text=True).stdout

            subprocess.run(["git", "init", "-q", "--bare", "-b", "main", str(origin)], check=True)
            subprocess.run(["git", "clone", "-q", str(origin), str(work)], check=True, capture_output=True)
            g("config", "user.email", "t@t"), g("config", "user.name", "t")
            g("checkout", "-q", "-b", "main")
            Path(work, "a").write_text("a\n"), g("add", "a"), g("commit", "-qm", "a")
            g("push", "-q", "origin", "main")
            for name in ("task/AA-10", "task/AA-11", "task/AA-12"):
                g("checkout", "-q", "-b", name, "main")
                Path(work, name.replace("/", "_")).write_text("x\n"), g("add", "-A"), g("commit", "-qm", name)
            g("checkout", "-q", "main"), g("fetch", "-q", "origin")

            later = NOW + 365 * 24 * HOUR
            statuses = {"AA-10": "in_review", "AA-11": "done", "AA-12": "cancelled"}
            asked = []

            def status_of(ident):
                asked.append(ident)
                return statuses[ident]

            self.assertEqual(m.stranded_branches(work, True, later, status_of),
                             [{"branch": "task/AA-10", "ahead": 1, "pushed": True}])
            m.stranded_branches(work, False, later, status_of)
            heads = g("ls-remote", "--heads", "origin")
            self.assertIn("refs/heads/task/AA-10", heads)
            self.assertNotIn("refs/heads/task/AA-11", heads)
            self.assertNotIn("refs/heads/task/AA-12", heads)

            # Only branches that would be pushed are looked up: AA-10 now has an origin
            # copy, so the next pass asks about the two finished ones and nothing else.
            asked.clear()
            m.stranded_branches(work, True, later, status_of)
            self.assertEqual(sorted(asked), ["AA-11", "AA-12"])

    def test_an_unreadable_status_holds_the_push_and_reports_it(self):
        with tempfile.TemporaryDirectory() as tmp:
            origin, work = Path(tmp, "origin.git"), Path(tmp, "work")

            def g(*args):
                return subprocess.run(["git", *args], cwd=work, check=True, capture_output=True, text=True).stdout

            subprocess.run(["git", "init", "-q", "--bare", "-b", "main", str(origin)], check=True)
            subprocess.run(["git", "clone", "-q", str(origin), str(work)], check=True, capture_output=True)
            g("config", "user.email", "t@t"), g("config", "user.name", "t")
            g("checkout", "-q", "-b", "main")
            Path(work, "a").write_text("a\n"), g("add", "a"), g("commit", "-qm", "a")
            g("push", "-q", "origin", "main")
            g("checkout", "-q", "-b", "task/AA-20", "main")
            Path(work, "b").write_text("b\n"), g("add", "b"), g("commit", "-qm", "b")
            g("checkout", "-q", "main"), g("fetch", "-q", "origin")

            def unreadable(ident):
                raise OSError("server down")

            self.assertEqual(m.stranded_branches(work, False, NOW + 365 * 24 * HOUR, unreadable),
                             [{"branch": "task/AA-20", "ahead": 1, "pushed": False, "note": "task status unread"}])
            self.assertNotIn("task/AA-20", g("ls-remote", "--heads", "origin"))

    def test_task_of_reads_the_identifier_reap_reads(self):
        self.assertEqual(m.task_of("task/AA-18"), "AA-18")
        self.assertEqual(m.task_of("task/AA-18-retry"), "AA-18")
        self.assertIsNone(m.task_of("task/none"))


class SweepStranded(unittest.TestCase):
    """The sweep looks tasks up one at a time, never by listing the closed ones."""

    class Api:
        dry_run = True

        def __init__(self, answers=None):
            self.queries, self.paths, self.answers = [], [], answers or {}

        def get(self, path):
            self.paths.append(path)
            answer = self.answers.get(path)
            if isinstance(answer, Exception):
                raise answer
            return answer if answer is not None else []

        def issues(self, **query):
            self.queries.append(query.get("status"))
            return []

    def test_the_sweep_reads_no_closed_task_list(self):
        seen = {}
        api = self.Api({"/issues/AA-1": {"status": "cancelled"}})
        saved = (m.merged_branches, m.stranded_branches, m.nightly, m.REPORT_FILE)
        try:
            m.merged_branches = lambda *a, **k: []
            m.nightly = lambda *a, **k: {}
            m.stranded_branches = lambda project, dry_run, now, status_of=None: seen.setdefault("s", status_of) and []
            with tempfile.TemporaryDirectory() as tmp:
                m.REPORT_FILE = Path(tmp, "none.json")
                m.sweep(api, Path(tmp), set(), [])
        finally:
            m.merged_branches, m.stranded_branches, m.nightly, m.REPORT_FILE = saved
        self.assertFalse(any(q and ("done" in q or "cancelled" in q) for q in api.queries))
        self.assertEqual(seen["s"]("AA-1"), "cancelled")
        self.assertIn("/issues/AA-1", api.paths)

    def test_task_status(self):
        class Missing(Exception):
            code = 404

        api = self.Api({"/issues/AA-1": {"status": "done"}, "/issues/AA-2": Missing(),
                        "/issues/AA-3": OSError("down"), "/issues/AA-4": {"error": "x"}})
        self.assertEqual(m.task_status(api, "AA-1"), "done")
        self.assertIsNone(m.task_status(api, "AA-2"))  # no such task: nothing else owns the branch
        with self.assertRaises(OSError):
            m.task_status(api, "AA-3")
        with self.assertRaises(ValueError):
            m.task_status(api, "AA-4")  # an error body is not a status


if __name__ == "__main__":
    unittest.main()
