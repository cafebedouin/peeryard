"""Unit tests for the daily history of queue/build.py (history/<date>.json and history/index.json); no network.
Run: python3 -m unittest tests/queue_history_test.py"""
import json
import os
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "queue"))
import build  # noqa: E402


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
        old = build.fetch_json
        try:
            build.fetch_json = lambda url: served.get(url.split("?")[0])
            self.assertEqual(build.load_history("https://s/"), {"2026-10-18": {"date": "2026-10-18"}})  # not a date: skipped
            del served["https://s/history/index.json"]
            self.assertEqual(build.load_history("https://s"), {})                 # no index yet: no history yet
            served["https://s/history/index.json"] = {"dates": ["2026-10-17"]}
            with self.assertRaises(RuntimeError):                                  # listed but not served: never shorten
                build.load_history("https://s")
        finally:
            build.fetch_json = old


if __name__ == "__main__":
    unittest.main()
