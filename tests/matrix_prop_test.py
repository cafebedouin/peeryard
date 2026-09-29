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

    def test_capture_loss_counts_only_the_counted_directions(self):
        gap = lambda link, frm: {"kind": "gap", "link": link, "from": frm, "t_ms": 1, "bytes": 9}
        self.assertEqual(M.per_run([gap("A-B", "A"), gap("B-C", "B"), gap("A-B", "B"), gap("B-C", "C")])["capture_loss"], 2)
        self.assertEqual(M.per_run([ib(0, "A-B", "A", "x")])["capture_loss"], 0)

    def test_run_with_capture_loss_is_left_out_of_the_pool(self):
        import io, json, tempfile, contextlib
        with tempfile.TemporaryDirectory() as d:
            for run, extra in (("fix-d0-1", []), ("fix-d0-2", [{"kind": "gap", "link": "A-B", "from": "A", "t_ms": 1}])):
                os.makedirs(os.path.join(d, run))
                with open(os.path.join(d, run, "messages.jsonl"), "w") as fh:
                    for m in [ib(0, "A-B", "A", "x"), ib(9, "B-C", "B", "x")] + extra:
                        fh.write(json.dumps(m) + "\n")
            buf = io.StringIO()
            with contextlib.redirect_stdout(buf):
                M.main([os.path.join(d, "fix-d0-1"), os.path.join(d, "fix-d0-2")])
        out = buf.getvalue()
        self.assertIn("fix-d0-2 EXCLUDED: 1 capture gap(s)", out)
        self.assertIn("ARM fix-d0 input: reach_C per run [1.0];", out)

    def test_nothing_sent_is_none(self):
        self.assertIsNone(M.per_run([])[100]["reach_C"])


if __name__ == "__main__":
    unittest.main()
