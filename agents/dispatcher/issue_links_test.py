"""Decision tests for issue_links.py.  Run: python3 -m unittest agents/dispatcher/issue_links_test.py"""

import importlib.util
import sys
import unittest
from pathlib import Path

_spec = importlib.util.spec_from_file_location("issue_links", Path(__file__).with_name("issue_links.py"))
issue_links = importlib.util.module_from_spec(_spec)
sys.modules["issue_links"] = issue_links
_spec.loader.exec_module(issue_links)


def gh(number, *labels, title="an issue"):
    return {"number": number, "title": title, "labels": [{"name": n} for n in labels]}


def link(number, status, ident="AA-1", parent=None, title="a task"):
    return {"number": number, "status": status, "identifier": ident, "parentId": parent,
            "title": title, "issueId": "id-" + ident}


class Classify(unittest.TestCase):
    def test_finished_work_no_roadmap_line_closes(self):
        v = issue_links.classify([gh(7, "roadmapped")], [link(7, "done")], set())
        self.assertEqual([i["number"] for i, _ in v.close], [7])
        self.assertEqual(v.orphans, [])

    def test_a_roadmap_line_keeps_a_sliced_issue_open(self):
        # The first slices landed; the rest still sit unfiled on the roadmap.
        v = issue_links.classify([gh(7, "roadmapped")], [link(7, "done")], {7})
        self.assertEqual(v.close, [])
        self.assertEqual(v.orphans, [])

    def test_a_live_task_keeps_it_open(self):
        for status in issue_links.ACTIVE:
            v = issue_links.classify([gh(7)], [link(7, "done"), link(7, status, "AA-2")], set())
            self.assertEqual(v.close, [], status)

    def test_cancelled_only_never_closes(self):
        v = issue_links.classify([gh(7)], [link(7, "cancelled")], set())
        self.assertEqual(v.close, [])

    def test_roadmapped_and_uncovered_is_an_orphan(self):
        v = issue_links.classify([gh(7, "roadmapped"), gh(8, "roadmapped")],
                                 [link(8, "cancelled")], set())
        self.assertEqual([i["number"] for i in v.orphans], [7, 8])

    def test_an_issue_not_yet_triaged_is_no_orphan(self):
        v = issue_links.classify([gh(7), gh(8, "ops")], [], set())
        self.assertEqual(v.orphans, [])

    def test_the_orphan_task_itself_covers_its_issues(self):
        # The Planner task is linked to the orphans, so the next sweep files nothing twice.
        v = issue_links.classify([gh(7, "roadmapped")], [link(7, "todo", "AA-9")], set())
        self.assertEqual(v.orphans, [])
        self.assertEqual(v.close, [])


class Mentions(unittest.TestCase):
    def test_reads_every_issue_marker(self):
        text = "- Fix it (#12). Slice (part of #345); see operator issue #6 and #7a."
        self.assertEqual(issue_links.mentions(text), {12, 345, 6})


class CloseComment(unittest.TestCase):
    def test_lists_top_level_tasks_with_their_prs(self):
        body = issue_links.close_comment(
            [link(7, "done", "AA-1", title="slice one"), link(7, "done", "AA-2", parent="p", title="Verify"),
             link(7, "cancelled", "AA-3", title="slice two")],
            {"task/AA-1": 41},
        )
        self.assertIn("- AA-1 (done): slice one — #41", body)
        self.assertIn("- AA-3 (cancelled): slice two", body)
        self.assertNotIn("Verify", body)


class PrNumbers(unittest.TestCase):
    def test_a_train_head_counts_as_its_task(self):
        prs = [{"headRefName": "train/3/AA-5", "number": 9}, {"headRefName": "task/AA-6", "number": 10}]
        orig = issue_links._run
        issue_links._run = lambda cmd, project: __import__("json").dumps(prs)
        try:
            out = issue_links.pr_numbers(Path("."))
        finally:
            issue_links._run = orig
        self.assertEqual(out["task/AA-5"], 9)
        self.assertEqual(out["task/AA-6"], 10)


class Sweep(unittest.TestCase):
    class FakeApi:
        dry_run = False

        def __init__(self, links):
            self.links, self.writes = links, []

        def get(self, path):
            return self.links

        def write(self, method, path, body, what):
            self.writes.append((method, path, body))

    def run_sweep(self, issues, links, mentioned, planner="planner-id"):
        calls = []

        def fake_run(cmd, project):
            calls.append(cmd)
            if cmd[:3] == ["gh", "repo", "view"]:
                return "owner/game\n"
            if cmd[:3] == ["gh", "issue", "list"]:
                return __import__("json").dumps(issues)
            if cmd[:3] == ["gh", "pr", "list"]:
                return "[]"
            return ""

        saved = issue_links._run, issue_links.roadmap_mentions
        issue_links._run = fake_run
        issue_links.roadmap_mentions = lambda project: mentioned
        api = self.FakeApi(links)
        try:
            result = issue_links.sweep(api, Path("."), planner)
        finally:
            issue_links._run, issue_links.roadmap_mentions = saved
        return result, api, calls

    def test_closes_and_files_one_linked_planner_task(self):
        (closed, orphans), api, calls = self.run_sweep(
            [gh(7, "roadmapped"), gh(8, "roadmapped"), gh(9, "roadmapped")], [link(7, "done")], {1})
        self.assertEqual((closed, orphans), (1, 2))
        self.assertIn(["gh", "issue", "close", "7"], [c[:4] for c in calls])
        [(method, path, body)] = api.writes
        self.assertEqual((method, path), ("POST", "/issues"))
        self.assertEqual(body["assigneeAgentId"], "planner-id")
        self.assertEqual(body["githubIssues"], [{"repo": "owner/game", "number": 8}, {"repo": "owner/game", "number": 9}])

    def test_closes_stop_at_the_cap(self):
        issues = [gh(n) for n in range(1, 20)]
        links = [link(n, "done", f"AA-{n}") for n in range(1, 20)]
        (closed, _), _, calls = self.run_sweep(issues, links, {999})
        self.assertEqual(closed, issue_links.MAX_CLOSES)
        self.assertEqual(sum(1 for c in calls if c[:3] == ["gh", "issue", "close"]), issue_links.MAX_CLOSES)

    def test_an_unreadable_roadmap_closes_nothing(self):
        def boom(project):
            raise RuntimeError("no issue number")
        saved = issue_links.roadmap_mentions
        issue_links.roadmap_mentions = boom
        orig_run = issue_links._run
        issue_links._run = lambda cmd, project: "owner/game"
        try:
            self.assertEqual(issue_links.sweep(self.FakeApi([link(7, "done")]), Path("."), "p"), (0, 0))
        finally:
            issue_links.roadmap_mentions, issue_links._run = saved, orig_run


if __name__ == "__main__":
    unittest.main()
