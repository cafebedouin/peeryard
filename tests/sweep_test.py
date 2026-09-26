#!/usr/bin/env python3
"""Tests for diag/sweep.py: line templates, run discovery, robust z, and novelty against a baseline. No nodes:
synthetic logs in the node's format.

  python3 tests/sweep_test.py
"""
import math
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "diag"))
import sweep as W  # noqa: E402


def write(path, lines):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write("".join(f"10:00:{i:02d}.000 {lvl}  [dispatcher-1] {text}\n" for i, (lvl, text) in enumerate(lines)))


COMMON = [("INFO", "o.e.n.h.ErgoHistory$$anon$1 - New best header " + "ab" * 32 + " with score 1. New height 5, old height 4"),
          ("INFO", "s.c.n.NetworkController - Connecting to /10.0.0.1:9001")]


class Templates(unittest.TestCase):
    def test_normalizes_ids_numbers_addresses_threads(self):
        a = W.template("10:00:00.000 INFO  [x] o.e.m.ErgoMiningThread - Starting miner thread: ErgoMiningThread-oVymN")
        b = W.template("11:22:33.444 INFO  [y] o.e.m.ErgoMiningThread - Starting miner thread: ErgoMiningThread-X91iX")
        self.assertEqual(a, b)
        t = W.template("10:00:00.000 WARN  [x] c - Modifier " + "f0" * 32 + " at 10.1.2.3:9001 height 17 obj@1a2b3c")
        self.assertEqual(t, ("WARN", "c - Modifier <h> at <ip> height <n> obj@<o>"))
        self.assertIsNone(W.template("Options: -Dfoo=1"))

    def test_robust_z_constant_majority(self):
        self.assertEqual(W.robust_z([2, 2, 2, 2, 2, 2, 2, 2, 2, 5], rare_cut=1)[-1], math.inf)
        self.assertEqual(W.robust_z([2, 2, 2, 2, 2, 2, 5, 5, 5, 5], rare_cut=1), [0.0] * 10,
                         "four of ten off a constant is ordinary spread, not an outlier")


class Discovery(unittest.TestCase):
    def test_log_dir_names_stand_for_their_parent(self):
        with tempfile.TemporaryDirectory() as d:
            write(os.path.join(d, "run1", "ci-logs", "x-node10-aa.log"), COMMON)
            write(os.path.join(d, "a", "b", "run2", "node_C.log"), COMMON)
            runs = W.find_runs([d])
            self.assertEqual(sorted(os.path.relpath(r, d) for r in runs), ["a/b/run2", "run1"])


class Novelty(unittest.TestCase):
    def test_new_message_transition_and_range(self):
        with tempfile.TemporaryDirectory() as d:
            for i in range(3):
                write(os.path.join(d, "base", f"r{i}", "node_A.log"), COMMON)
            write(os.path.join(d, "new", "r9", "node_A.log"),
                  [COMMON[1], COMMON[0], ("WARN", "c - something never seen 42")])
            known = W.baseline([os.path.join(d, "base")])
            found = W.novelty(W.find_runs([os.path.join(d, "new")]), known)
            kinds = {(x["kind"], x["pattern"].split("  ")[0][:40]) for x in found}
            self.assertIn(("new message", "WARN c - something never seen <n>"), kinds)
            self.assertTrue(any(x["kind"] == "new transition" for x in found), "Connecting -> header never followed")
            self.assertEqual(found[0]["kind"], "new message", "new messages rank first")

    def test_nothing_new(self):
        with tempfile.TemporaryDirectory() as d:
            for i in range(2):
                write(os.path.join(d, "base", f"r{i}", "node_A.log"), COMMON)
            write(os.path.join(d, "new", "r9", "node_A.log"), COMMON)
            known = W.baseline([os.path.join(d, "base")])
            self.assertEqual(W.novelty(W.find_runs([os.path.join(d, "new")]), known), [])


if __name__ == "__main__":
    unittest.main()
