"""Decision tests for mechanical.py.  Run: python3 -m unittest agents/facilitator/mechanical_test.py"""

import importlib.util
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


def stalled(issues, runs=(), paused=(), skip=None, quiet=None):
    return [i["identifier"] for i in m.missed_wakes(issues, list(runs), set(paused), skip, NOW, quiet)]


class MissedWakes(unittest.TestCase):
    def test_an_assigned_stage_with_no_run_past_the_threshold_is_stalled(self):
        self.assertEqual(stalled([task("A")]), ["A"])

    def test_a_recent_stage_is_not_yet_stalled(self):
        self.assertEqual(stalled([task("A", hours_ago=1)]), [])

    def test_a_worker_parent_in_review_is_waiting_on_its_children(self):
        self.assertEqual(stalled([task("A", title="§4.1 Author a thing", agent="worker")]), [])

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


class Branches(unittest.TestCase):
    def test_young_branches_and_open_pr_heads_are_never_candidates(self):
        rows = [("old", NOW - 48 * HOUR), ("young", NOW - HOUR), ("pr", NOW - 48 * HOUR)]
        self.assertEqual(m.deletable(rows, {"pr"}, NOW), ["old"])

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
            tree = g("rev-parse", "origin/main^{tree}").strip()

            self.assertEqual(sorted(b for b, _ in m.remote_branches(work)), ["merged", "squashed", "unlanded"])
            self.assertEqual(m.on_main(work, "merged", tree), "tip is on origin/main")
            self.assertEqual(m.on_main(work, "squashed", tree), "merging it into origin/main changes nothing")
            self.assertIsNone(m.on_main(work, "unlanded", tree))


if __name__ == "__main__":
    unittest.main()
