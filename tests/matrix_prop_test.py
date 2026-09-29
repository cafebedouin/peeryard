"""tests for diag/matrix_prop.py (standard library only)."""
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "diag"))
import matrix_prop as M  # noqa: E402


def ib(t, link, frm, i):
    return {"kind": "frame", "code": 100, "link": link, "from": frm, "t_ms": t, "input_block_id": i}


class Prop(unittest.TestCase):
    def test_reach_hop_and_duplicates(self):
        msgs = [ib(0, "A-B", "A", "x"), ib(5, "A-B", "A", "x"), ib(10, "A-B", "A", "y"),
                ib(460, "B-C", "B", "x"), ib(1000, "B-A", "B", "z")]
        r = M.per_run(msgs)[100]
        self.assertEqual((r["sent_AB"], r["sent_BC"], r["relayed"], r["reach_C"], r["hop_ms"]), (2, 1, 1, 0.5, [460]))
        self.assertEqual(sorted(r["dup_AB"]), [1, 2])

    def test_no_relay_is_zero_reach(self):
        r = M.per_run([ib(0, "A-B", "A", "x")])[100]
        self.assertEqual((r["reach_C"], r["hop_ms"]), (0.0, []))

    def test_nothing_sent_is_none(self):
        self.assertIsNone(M.per_run([])[100]["reach_C"])


if __name__ == "__main__":
    unittest.main()
