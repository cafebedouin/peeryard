"""Unit tests for the daily history of queue/build.py (history/<date>.json and history/index.json); no network.
Run: python3 -m unittest tests/queue_history_test.py"""
import contextlib
import io
import json
import os
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "queue"))
import build  # noqa: E402
import ghapi  # noqa: E402
import history  # noqa: E402
import posts  # noqa: E402


def snap(at, groups):
    exact = [{"patch_id": "p" * 40, "prs": g, "files": ["src/main/A.scala"], "changed_lines": 2} for g in groups]
    related = [{"issue": 9, "prs": [1, 3], "pairs": [{"prs": [1, 3], "shared_files": 1}]}]
    return build.snapshot(at, "o/r", [{}] * 5, [{}] * 4, exact, related, None, [])


class History(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.out = self.tmp.name

    def tearDown(self):
        self.tmp.cleanup()

    def read(self, name):
        with open(os.path.join(self.out, "history", name)) as f:
            return json.load(f)

    def test_accumulates_and_same_day_replaces(self):
        build.write_history(self.out, build.load_history(self.out), snap("2026-10-18T06:17:00Z", [[1, 2]]))
        build.write_history(self.out, build.load_history(self.out), snap("2026-10-19T06:17:00Z", [[1, 2]]))
        dates = build.write_history(self.out, build.load_history(self.out), snap("2026-10-19T13:00:00Z", [[1, 2], [3, 4]]))
        self.assertEqual(dates, ["2026-10-18", "2026-10-19"])
        idx = self.read("index.json")
        self.assertEqual((idx["dates"], idx["latest"]), (["2026-10-18", "2026-10-19"], "2026-10-19"))
        day = self.read("2026-10-19.json")
        self.assertEqual(day["generated_at"], "2026-10-19T13:00:00Z")            # the later run of the day
        self.assertEqual([g["prs"] for g in day["same_change"]], [[1, 2], [3, 4]])
        self.assertEqual(day["same_issue"], [{"issue": 9, "prs": [1, 3], "pairs": [[1, 3]]}])
        self.assertEqual((day["open_prs"], day["open_ready_prs"], day["same_change"][0]["files"]), (5, 4, 1))
        self.assertEqual(self.read("2026-10-18.json")["date"], "2026-10-18")      # the earlier day kept

    def test_published_site(self):
        served = {"https://s/history/index.json": {"dates": ["2026-10-18", "../x"]},
                  "https://s/history/2026-10-18.json": {"date": "2026-10-18"}}
        old = history.fetch_json                 # load_history's lookup (queue/history.py)
        try:
            history.fetch_json = lambda url: served.get(url.split("?")[0])
            self.assertEqual(build.load_history("https://s/"), {"2026-10-18": {"date": "2026-10-18"}})  # not a date: skipped
            del served["https://s/history/index.json"]
            self.assertEqual(build.load_history("https://s"), {})                 # no index yet: no history yet
            served["https://s/history/index.json"] = {"dates": ["2026-10-17"]}
            with self.assertRaises(RuntimeError):                                  # listed but not served: never shorten
                build.load_history("https://s")
        finally:
            history.fetch_json = old




H, O = "b" * 40, "a" * 40
COMMIT = {"commit": {"committer": {"date": "2026-11-01T00:00:00Z"}}}


def fake_api(responses):
    def api(path, params=None, token=None, paginate=False):
        for key, val in responses.items():
            if key in path:
                if isinstance(val, Exception):
                    raise val
                return val(params) if callable(val) else val
        raise AssertionError(path)
    return api


class AtHead(unittest.TestCase):
    """A review or post counts at the head by the head's push time, not its committer date (a commit written before
    an earlier review and pushed after it must not inherit that review)."""

    def setUp(self):
        # head_push_time calls posts.api, search_numbers ghapi.api: each module's own lookup is the one replaced
        for mod in (posts, ghapi):
            self.addCleanup(setattr, mod, "api", mod.api)

    def test_push_time_sources(self):
        ts = build.parse_ts
        posts.api = fake_api({"/timeline": [{"event": "committed"}],
                              "/check-suites": {"check_suites": [{"created_at": "2026-11-10T00:00:00Z"}]}})
        self.assertEqual(build.head_push_time("o/r", 7, H, COMMIT, None), (ts("2026-11-10T00:00:00Z"), "check-suite"))
        posts.api = fake_api({"/timeline": [
            {"event": "head_ref_force_pushed", "commit_id": H, "created_at": "2026-11-12T00:00:00Z"},
            {"event": "head_ref_force_pushed", "commit_id": O, "created_at": "2026-11-13T00:00:00Z"}]})
        self.assertEqual(build.head_push_time("o/r", 7, H, COMMIT, None), (ts("2026-11-12T00:00:00Z"), "force-push"))
        posts.api = fake_api({"/timeline": RuntimeError("502"), "/check-suites": {"check_suites": []}})
        self.assertEqual(build.head_push_time("o/r", 7, H, COMMIT, None), (ts("2026-11-01T00:00:00Z"), "committer-date"))

    def test_reviews_by_commit_id(self):
        ts = build.parse_ts
        at = ts("2026-11-10T00:00:00Z")
        old = {"state": "COMMENTED", "submitted_at": "2026-11-05T00:00:00Z", "commit_id": O}
        self.assertFalse(build.review_at_head(old, H, ts("2026-11-01T00:00:00Z")))
        self.assertTrue(build.review_at_head(dict(old, state="APPROVED", commit_id=H), H, at))
        self.assertFalse(build.review_at_head({"state": "PENDING", "submitted_at": None, "commit_id": H}, H, at))
        self.assertTrue(build.review_at_head({"state": "COMMENTED", "submitted_at": "2026-11-11T00:00:00Z"}, H, at))

    def test_posts_by_push_time_or_named_head(self):
        ts = build.parse_ts
        at = ts("2026-11-10T00:00:00Z")
        before = {"at": ts("2026-11-06T00:00:00Z"), "commit_id": None, "head": None}
        self.assertFalse(build.post_at_head(before, H, at))
        self.assertTrue(build.post_at_head(dict(before, at=ts("2026-11-11T00:00:00Z")), H, at))
        self.assertFalse(build.post_at_head(dict(before, at=ts("2026-11-11T00:00:00Z"), head=O), H, at))
        self.assertTrue(build.post_at_head(dict(before, head=H), H, at))

    def test_search_pages_until_a_short_page(self):
        pages = {1: list(range(100)), 2: list(range(100, 200)), 3: list(range(200, 250))}
        ghapi.api = fake_api({"/search/issues": lambda p: {"items": [{"number": n} for n in pages[p["page"]]]}})
        self.assertEqual(len(build.search_numbers("q", None)), 250)

        def flaky(p):
            if p["page"] == 2:
                raise RuntimeError("HTTP 422")
            return {"items": [{"number": n} for n in pages[p["page"]]]}
        ghapi.api = fake_api({"/search/issues": flaky})
        with contextlib.redirect_stderr(io.StringIO()), contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(len(build.search_numbers("q", None)), 100)

if __name__ == "__main__":
    unittest.main()
