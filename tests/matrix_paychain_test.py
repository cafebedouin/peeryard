"""tests for diag/matrix_paychain.py (standard library only)."""
import contextlib
import io
import json
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "diag"))
import matrix_paychain as M  # noqa: E402


def run_dir(d, name, pays, confirmed, pool):
    p = os.path.join(d, name)
    os.makedirs(p)
    with open(os.path.join(p, "payments.jsonl"), "w") as fh:
        for x in pays:
            fh.write(json.dumps(x) + "\n")
    with open(os.path.join(p, "confirmed.jsonl"), "w") as fh:
        for i in confirmed:
            fh.write(json.dumps({"id": i, "height": 5}) + "\n")
    with open(os.path.join(p, "a_pool_end.txt"), "w") as fh:
        fh.write("\n".join(pool) + ("\n" if pool else ""))
    return p


# p1 spends a confirmed box; p2 spends p1's change (dependent); p3 spends p2's change (dependent);
# p4 independent. p1 and p4 confirmed, p2 lost, p3 still pending in A's pool.
PAYS = [{"id": "p1", "inputs": ["c1"], "outputs": ["b", "p1chg"]},
        {"id": "p2", "inputs": ["p1chg"], "outputs": ["b2", "p2chg"]},
        {"id": "p3", "inputs": ["p2chg", "c3"], "outputs": ["b3"]},
        {"id": "p4", "inputs": ["c4"], "outputs": ["b4"]}]


class Classify(unittest.TestCase):
    def test_dependent_lost_pending(self):
        with tempfile.TemporaryDirectory() as d:
            r = M.classify(run_dir(d, "base-1", PAYS, ["p1", "p4"], ["p3"]))
        self.assertEqual((r["accepted"], r["dependent"], r["confirmed"], r["dependent_confirmed"], r["lost"],
                          r["dependent_lost"], r["pending"]), (4, 2, 2, 0, 1, 1, 1))

    def test_an_output_of_a_later_payment_does_not_make_an_earlier_one_dependent(self):
        pays = [{"id": "a", "inputs": ["x"], "outputs": ["y"]}, {"id": "b", "inputs": ["z"], "outputs": ["x"]}]
        with tempfile.TemporaryDirectory() as d:
            self.assertEqual(M.classify(run_dir(d, "r-1", pays, ["a", "b"], []))["dependent"], 0)

    def test_unknown_inputs_are_counted_not_guessed(self):
        pays = [{"id": "a", "inputs": None, "outputs": None}]
        with tempfile.TemporaryDirectory() as d:
            r = M.classify(run_dir(d, "r-1", pays, [], []))
        self.assertEqual((r["unknown_inputs"], r["dependent"], r["lost"]), (1, 0, 1))

    def test_pool_sums_per_arm(self):
        with tempfile.TemporaryDirectory() as d:
            a = run_dir(d, "base-1", PAYS, ["p1", "p4"], ["p3"])
            b = run_dir(d, "pr2504-1", PAYS, ["p1", "p2", "p3", "p4"], [])
            buf = io.StringIO()
            with contextlib.redirect_stdout(buf):
                M.main(["--pool", a, b])
        out = buf.getvalue()
        self.assertIn("ARM base: runs 1, runs with a lost payment 1; accepted 4, dependent 2 (confirmed 0, lost 1)", out)
        self.assertIn("ARM pr2504: runs 1, runs with a lost payment 0; accepted 4, dependent 2 (confirmed 2, lost 0)", out)


if __name__ == "__main__":
    unittest.main()
