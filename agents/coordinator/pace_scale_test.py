"""Tests for pace-scale.py.  Run: python3 -m unittest agents/coordinator/pace_scale_test.py"""

import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import time
import unittest
from datetime import datetime, timezone
from pathlib import Path

SCRIPT = Path(__file__).with_name("pace-scale.py")


def run(usage: dict | str) -> dict:
    with tempfile.TemporaryDirectory() as d:
        path = Path(d, "usage.json")
        path.write_text(usage if isinstance(usage, str) else json.dumps(usage))
        env = {**os.environ, "CLOUD_PACE_USAGE_FILE": str(path)}
        out = subprocess.run([sys.executable, str(SCRIPT)], env=env, capture_output=True, text=True, check=True)
        return json.loads(out.stdout)


def week(used: float, session: float = 0) -> dict:
    reset = datetime.fromtimestamp(time.time() + 86400, tz=timezone.utc).isoformat()
    return {"five_hour": {"utilization": session}, "seven_day": {"utilization": used, "resets_at": reset}}


class FollowsTheGate(unittest.TestCase):
    def test_open_gate_is_full_width_however_far_ahead_of_pace(self):
        # One day left in the week and 91% used is ahead of pace; only the ceiling decides.
        k = run(week(91, session=95))
        self.assertTrue(k["open"])
        self.assertEqual(k["promote_slots"], k["worker_slots"])
        self.assertEqual(k["planner_floor"], 40)
        self.assertEqual(k["writer_threshold"], 2)

    def test_closed_gate_stops_new_work_but_keeps_worker_slots(self):
        k = run(week(98))
        self.assertFalse(k["open"])
        self.assertEqual(k["promote_slots"], 0)
        self.assertEqual(k["planner_floor"], 0)
        self.assertEqual(k["worker_slots"], 12)

    def test_unreadable_usage_closes_like_the_gate(self):
        self.assertFalse(run("not json")["open"])

    def test_same_ceiling_as_the_cloud_lane(self):
        spec = importlib.util.spec_from_file_location("cloud_pace", SCRIPT.parent.parent / "architect" / "cloud-pace.py")
        cloud_pace = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cloud_pace)
        below = cloud_pace.WEEK_CEILING - 1
        self.assertTrue(run(week(below))["open"])
        self.assertFalse(run(week(cloud_pace.WEEK_CEILING))["open"])


if __name__ == "__main__":
    unittest.main()
