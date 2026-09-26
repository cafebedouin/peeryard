#!/usr/bin/env python3
"""Tests for diag/features.py: feature extraction from Ergo node log lines, container ordering, and ranking. No nodes:
each case writes small synthetic logs in the node's log format to a temporary directory.

  python3 tests/features_test.py
"""
import gzip
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "diag"))
import features as F  # noqa: E402

ID = "ab" * 32


def line(t, text, level="INFO"):
    return f"{t} {level}  [dispatcher-1] {text}\n"


def header(t, h):
    return line(t, f"o.e.n.h.ErgoHistory$$anon$1 - New best header {ID} with score 1. New height {h}, old height {h - 1}")


def full(t, h):
    return line(t, f"o.e.n.state.UtxoState - Valid modifier with header {ID} and emission box Some({ID}) "
                   f"applied to UtxoState at height {h}")


def switch(t, apply, remove):
    return line(t, f"o.e.n.h.ErgoHistory$$anon$1 - Full block {ID} appended, going to apply {apply} and to remove "
                   f"{remove} modifiers.")


def write(path, text, gz=False):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with (gzip.open(path, "wt") if gz else open(path, "w")) as f:
        f.write(text)


class Extraction(unittest.TestCase):
    def test_lead_and_switch(self):
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, "node_C.log")
            write(p, header("10:00:00.000", 10) + full("10:00:00.100", 10) + header("10:00:01.000", 30)
                  + switch("10:00:02.000", 5, 3) + full("10:00:02.100", 12)
                  + line("10:00:03.000", "o.e.n.w.ErgoWalletActor - Wallet: skipped blocks found starting from 9, going back")
                  + line("10:00:04.000", "boom", level="ERROR"))
            first, f = F.log_features(p)
            self.assertEqual(first, 36_000_000)
            self.assertEqual(f["final_header_height"], 30)
            self.assertEqual(f["final_full_height"], 12)
            self.assertEqual(f["final_lead"], 18)
            self.assertEqual(f["max_lead"], 20)
            self.assertEqual(f["first_switch_apply"], 5)
            self.assertEqual(f["first_switch_remove"], 3)
            self.assertEqual(f["first_switch_lead"], 20, "the lead going into the switch, before its own update")
            self.assertEqual(f["wallet_skipped"], 1)
            self.assertEqual(f["errors"], 1)

    def test_no_ergo_lines(self):
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, "node_A.log")
            write(p, "Options: -Dfoo=bar\nnot a node line\n")
            self.assertEqual(F.log_features(p), (None, {}))

    def test_containers_ordered_and_always_numbered(self):
        with tempfile.TemporaryDirectory() as d:
            write(os.path.join(d, "ci-logs", "ergo-itest-x-node10-bbbb.log"), header("10:05:00.000", 50))
            write(os.path.join(d, "ci-logs", "ergo-itest-x-node10-aaaa.log"), header("10:00:00.000", 7))
            write(os.path.join(d, "node_D.log.gz"), header("10:00:00.000", 3), gz=True)
            r = F.run_features(d)
            self.assertEqual(r["node10#1.final_header_height"], 7, "earliest container first")
            self.assertEqual(r["node10#2.final_header_height"], 50)
            self.assertEqual(r["D#1.final_header_height"], 3, "a single log is #1, gz read")


class Ranking(unittest.TestCase):
    def test_perfect_separator_ranks_first(self):
        rows = {f"f{i}": {"x.lead": v, "x.noise": n} for i, (v, n) in
                enumerate([(6, 1), (7, 5), (0, 2), (4, 6), (5, 3)])}
        labels = {"f0": "hung", "f1": "hung", "f2": "ok", "f3": "ok", "f4": "ok"}
        ranked = F.rank(rows, labels, "hung")
        self.assertEqual(ranked[0]["feature"], "x.lead")
        self.assertTrue(ranked[0]["separates"])
        self.assertEqual(ranked[0]["gap"], 1)
        self.assertFalse(ranked[1]["separates"])

    def test_lower_direction(self):
        rows = {"a": {"k": 13}, "b": {"k": 25}, "c": {"k": 32}, "d": {"k": 47}}
        labels = {"a": "empty", "b": "empty", "c": "returned", "d": "returned"}
        r = F.rank(rows, labels, "empty")[0]
        self.assertEqual((r["direction"], r["separates"], r["gap"]), ("lower", True, 7))

    def test_verdict_line(self):
        with tempfile.TemporaryDirectory() as d:
            write(os.path.join(d, "run.txt"), "[rig] === hook done (verdict: FAIL) ===\n")
            write(os.path.join(d, "node_A.log"), line("10:00:00.000", "(verdict: PASS) inside a node log is ignored"))
            self.assertEqual(F.run_verdict(d), "FAIL")


if __name__ == "__main__":
    unittest.main()
