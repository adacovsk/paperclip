"""Tests for the no-answer guard.  Run: python3 -m unittest agents/dispatcher/unreachable_test.py"""

import contextlib
import importlib.util
import io
import os
import sys
import unittest
import urllib.error
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).parent))
from unreachable import ApiUnreachable, skip_unreachable, transport_failure  # noqa: E402

_spec = importlib.util.spec_from_file_location("dispatch", Path(__file__).with_name("dispatch.py"))
dispatch = importlib.util.module_from_spec(_spec)
sys.modules["dispatch"] = dispatch
_spec.loader.exec_module(dispatch)


class _Resp:
    def __init__(self, raw: bytes):
        self.raw = raw

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False

    def read(self):
        return self.raw


def api() -> "dispatch.Api":
    return dispatch.Api(dry_run=False)


class TransportFailure(unittest.TestCase):
    def test_timeout_and_dropped_connection_are_no_answer(self):
        self.assertTrue(transport_failure(TimeoutError("timed out")))
        self.assertTrue(transport_failure(ConnectionResetError()))
        self.assertTrue(transport_failure(urllib.error.URLError("refused")))

    def test_an_http_refusal_is_an_answer(self):
        self.assertFalse(transport_failure(urllib.error.HTTPError("u", 409, "conflict", {}, None)))


class Call(unittest.TestCase):
    def setUp(self):
        sleep = mock.patch.object(dispatch.time, "sleep")
        sleep.start()
        self.addCleanup(sleep.stop)

    def test_a_get_that_times_out_once_is_retried(self):
        with mock.patch.object(dispatch.urllib.request, "urlopen",
                               side_effect=[TimeoutError("slow"), _Resp(b'{"ok": 1}')]) as urlopen:
            self.assertEqual(api().get("/x"), {"ok": 1})
        self.assertEqual(urlopen.call_count, 2)

    def test_a_get_that_never_answers_raises_unreachable(self):
        with mock.patch.object(dispatch.urllib.request, "urlopen", side_effect=TimeoutError("slow")) as urlopen:
            with self.assertRaises(ApiUnreachable):
                api().get("/x")
        self.assertEqual(urlopen.call_count, dispatch.GET_ATTEMPTS)

    def test_a_write_that_times_out_is_not_repeated(self):
        # It may have applied server-side; a repeat could apply it twice.
        with mock.patch.object(dispatch.urllib.request, "urlopen", side_effect=TimeoutError("slow")) as urlopen:
            with self.assertRaises(ApiUnreachable), contextlib.redirect_stdout(io.StringIO()):
                api().write("PATCH", "/issues/1", {"status": "todo"}, "w")
        self.assertEqual(urlopen.call_count, 1)

    def test_an_http_error_passes_through_unretried(self):
        err = urllib.error.HTTPError("u", 404, "missing", {}, None)
        with mock.patch.object(dispatch.urllib.request, "urlopen", side_effect=err) as urlopen:
            with self.assertRaises(urllib.error.HTTPError):
                api().get("/x")
        self.assertEqual(urlopen.call_count, 1)


class Guard(unittest.TestCase):
    def test_one_unreachable_item_costs_only_that_item(self):
        done = []
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            for item in ("a", "b", "c"):
                with skip_unreachable(f"item {item}"):
                    if item == "b":
                        raise ApiUnreachable("GET /b: timed out")
                    done.append(item)
        self.assertEqual(done, ["a", "c"])
        self.assertIn("item b: API unreachable", out.getvalue())

    def test_other_errors_still_propagate(self):
        with self.assertRaises(KeyError):
            with skip_unreachable("x"):
                raise KeyError("k")

    def test_it_records_whether_it_skipped(self):
        with contextlib.redirect_stdout(io.StringIO()):
            with skip_unreachable("x") as hit:
                raise ApiUnreachable("no")
        with skip_unreachable("y") as clean:
            pass
        self.assertTrue(hit.skipped)
        self.assertFalse(clean.skipped)


if __name__ == "__main__":
    unittest.main()
