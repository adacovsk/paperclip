"""Tests for pace-scale.py's stock read.  Run: python3 -m unittest agents/coordinator/pace_scale_test.py"""

import importlib.util
import os
import tempfile
import unittest
from pathlib import Path

_spec = importlib.util.spec_from_file_location("pace_scale", Path(__file__).with_name("pace-scale.py"))
pace_scale = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(pace_scale)


class BaseRedEscalations(unittest.TestCase):
    def test_names_the_escalating_task_or_the_marker_task(self):
        with tempfile.TemporaryDirectory() as d:
            Path(d, "AA-1.base-red").write_text("a" * 40 + "\nAA-11\nsrc/a.rs:1 E0252 dup import\n")
            Path(d, "AA-2.base-red").write_text("a" * 40 + "\n")
            Path(d, "AA-3.exit").write_text("1\n")
            self.assertEqual(pace_scale.base_red_escalations(d), {"AA-11", "AA-2"})

    def test_a_missing_directory_excludes_nothing(self):
        self.assertEqual(pace_scale.base_red_escalations(os.path.join(tempfile.gettempdir(), "no-such-dir-xyz")), set())


if __name__ == "__main__":
    unittest.main()
