"""tests for diag/txload_report.py and rig/lib/extminer.py's PoW hit (standard library only)."""
import contextlib
import io
import json
import os
import sys
import tempfile
import unittest

HERE = os.path.dirname(__file__)
sys.path.insert(0, os.path.join(HERE, "..", "diag"))
sys.path.insert(0, os.path.join(HERE, "..", "rig", "lib"))
import txload_report as T  # noqa: E402
import extminer as X  # noqa: E402


def write(d, name, rows):
    with open(os.path.join(d, name), "w") as fh:
        if isinstance(rows, dict):
            json.dump(rows, fh)
        else:
            for r in rows:
                fh.write(json.dumps(r) + "\n")


class Report(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.mkdtemp()
        # f1 funds B; p1 independent and confirmed (seen in an input block at B, then in block H5);
        # p2 spends p1's change (dependent), still in C's pool; p3 spends p2's change, lost; one rejected; one skipped tick
        write(self.d, "txload.jsonl", [
            {"t_ms": 1000, "kind": "fund", "node": "A", "to": "B", "seq": 0, "id": "f1", "inputs": ["c0"], "outputs": ["fb", "fchg"]},
            {"t_ms": 2000, "kind": "pay", "node": "A", "to": "C", "seq": 1, "id": "p1", "inputs": ["c1"], "outputs": ["pc", "p1chg"]},
            {"t_ms": 2300, "kind": "pay", "node": "A", "to": "C", "seq": 1, "id": "p2", "inputs": ["p1chg"], "outputs": ["pc2", "p2chg"]},
            {"t_ms": 2600, "kind": "pay", "node": "A", "to": "C", "seq": 1, "id": "p3", "inputs": ["p2chg"], "outputs": ["pc3"]},
            {"t_ms": 3000, "kind": "pay", "node": "B", "to": "A", "seq": 2, "id": None, "error": "no inputs"},
            {"t_ms": 4000, "kind": "skip", "seq": 3}])
        write(self.d, "txwatch.jsonl", [
            {"t_ms": 2900, "node": "B", "ev": "input", "ord": "o", "id": "ib1", "txs": ["p1", "f1"]},
            {"t_ms": 2500, "node": "A", "ev": "input", "ord": "o", "id": "ib0", "txs": ["p1"]},
            {"t_ms": 9000, "node": "C", "ev": "full", "h": 5, "id": "H5"},
            {"t_ms": 8000, "node": "A", "ev": "full", "h": 5, "id": "H5"}])
        write(self.d, "txload_chain.jsonl", [{"h": 5, "id": "H5", "ts": 7500, "txs": ["cb", "p1", "f1"]}])
        write(self.d, "txload_pools.json", {"A": [], "C": ["p2"]})

    def test_records_and_counts(self):
        recs, c = T.build(self.d)
        by = {r["id"]: r for r in recs}
        self.assertEqual(c["attempts"], 5)
        self.assertEqual((c["accepted"], c["rejected"], c["skipped_ticks"], c["fund"]), (4, 1, 1, 1))
        self.assertEqual((c["dependent"], c["confirmed"], c["pending"], c["lost"], c["dependent_lost"]), (2, 2, 1, 1, 1))
        # p2's parent p1 was first shown in a best block at 8000, after p2 was sent (2300); p3's parent p2 never
        self.assertEqual((c["unconfirmed_parent"], c["unconfirmed_parent_lost"]), (2, 1))
        self.assertFalse(by["p1"]["unconfirmed_parent"])
        self.assertEqual(by["p1"]["input"], {"t_ms": 2500, "node": "A", "id": "ib0"})
        self.assertEqual(by["p1"]["input_by_node"], {"A": 2500, "B": 2900})
        self.assertEqual(by["p1"]["ordering"], {"h": 5, "id": "H5", "ts": 7500, "seen_ms": 8000, "seen_node": "A"})
        self.assertEqual(by["p2"]["status"], "pending")
        self.assertEqual(by["p2"]["pending_in"], ["C"])
        self.assertTrue(by["p3"]["dependent"])
        self.assertEqual(by["p3"]["status"], "lost")
        self.assertEqual(c["input_ms_p50"], 500)      # p1 2000 -> 2500; f1 1000 -> 2900 = 1900
        self.assertEqual(c["ordering_ms_p50"], 6000)  # p1 6000, f1 7000

    def test_main_writes_records(self):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            self.assertEqual(T.main([self.d]), 0)
        self.assertTrue(out.getvalue().startswith("MATRIX-TXLOAD attempts=5 accepted=4"))
        with open(os.path.join(self.d, "txrecords.jsonl")) as fh:
            self.assertEqual(len(fh.readlines()), 4)

    def test_empty_run(self):
        d = tempfile.mkdtemp()
        recs, c = T.build(d)
        self.assertEqual((recs, c["accepted"], c["input_ms_p50"]), ([], 0, None))


class Pow(unittest.TestCase):
    def test_vector_height_614400(self):
        # ergo's AutolykosPowSchemeSpec "test vectors for first increase in N value (height 614,400)"
        msg = bytes.fromhex("548c3e602a8f36f8f2738f5f643b02425038044d98543a51cabaa9785e7e864f")
        self.assertEqual(X.calc_n(614400), 70464240)
        self.assertEqual(X.hit_v2(msg, bytes.fromhex("0000000000003105"), 614400),
                         int("0002fcb113fe65e5754959872dfdbffea0489bf830beb4961ddc0e9e66a1412a", 16))

    def test_calc_n_below_increase(self):
        self.assertEqual(X.calc_n(100), 2 ** 26)

    def test_parse_poll(self):
        self.assertEqual((X.parse_poll("500ms"), X.parse_poll("4s")), (0.5, 4.0))


if __name__ == "__main__":
    unittest.main()
