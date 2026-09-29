"""tests for diag/matrix_tx.py (standard library only)."""
import contextlib
import io
import json
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "diag"))
import matrix_tx as M  # noqa: E402

P1, P2 = "aa11bb" + "0" * 58, "cc22dd" + "1" * 58   # two payment ids; weak ids start with their first 6 hex


def f(t, link, frm, code, **kw):
    return dict(kind="frame", t_ms=t, link=link, conn=1, **{"from": frm}, code=code, **kw)


def run_dir(d, name, msgs, pays):
    p = os.path.join(d, name)
    os.makedirs(p)
    for fn, rows in (("messages.jsonl", msgs), ("payments.jsonl", pays)):
        with open(os.path.join(p, fn), "w") as fh:
            for m in rows:
                fh.write(json.dumps(m) + "\n")
    return p


PAYS = [{"t_ms": 0, "id": P1}, {"t_ms": 0, "id": P2}]


class Paths(unittest.TestCase):
    def test_mempool_path_when_the_body_crossed_before_the_listing(self):
        fwd = [f(100, "A-B", "A", 33, type_id=2, modifier_ids=[P1]),
               f(300, "A-B", "A", 100, input_block_id="ib", weak_tx_ids=1, weak_ids=["aa11bbeeeeee"])]
        rows = M.per_payment(PAYS[:1], fwd, [])
        self.assertEqual((rows[0]["path"], rows[0]["body_ms"], rows[0]["listed_ms"], rows[0]["via"]), ("mempool", 100, 300, 100))

    def test_asked_path_pairs_the_105_with_its_104(self):
        fwd = [f(200, "A-B", "A", 100, input_block_id="ib", weak_tx_ids=None),
               f(500, "A-B", "A", 102, input_block_id="ib", count=2, weak_ids=["aa11bbeeeeee", "cc22ddeeeeee"]),
               f(900, "A-B", "A", 104, input_block_id="ib", count=1),
               f(950, "A-B", "A", 33, type_id=2, modifier_ids=[P2])]
        back = [f(300, "A-B", "B", 22, type_id=-122, count=1, modifier_ids=["ib"]),
                f(700, "A-B", "B", 105, input_block_id="ib", count=1, weak_ids=["aa11bbeeeeee"])]
        rows = {r["id"]: r for r in M.per_payment(PAYS, fwd, back)}
        self.assertEqual((rows[P1]["path"], rows[P1]["via"], rows[P1]["answer_ms"]), ("asked", 102, 900))
        self.assertEqual(rows[P2]["path"], "other")   # listed at 500, body only at 950, never asked
        ex = M.exchanges(fwd, back)
        self.assertEqual((ex["ids_asked"], ex["ids_answered"], ex["req"], ex["full"], ex["answer_ms"]), (1, 1, 1, 1, [200]))

    def test_short_unanswered_repeated_and_unpaired(self):
        fwd = [f(400, "B-C", "B", 104, input_block_id="x", count=1), f(450, "B-C", "B", 104, input_block_id="z", count=1)]
        back = [f(100, "B-C", "C", 105, input_block_id="x", count=3, weak_ids=["01" * 6] * 3),
                f(200, "B-C", "C", 105, input_block_id="y", count=1, weak_ids=["02" * 6]),
                f(600, "B-C", "C", 105, input_block_id="x", count=1, weak_ids=["01" * 6])]
        ex = M.exchanges(fwd, back)
        self.assertEqual((ex["req"], ex["full"], ex["short"], ex["short_missing"], ex["unanswered"], ex["repeated"],
                          ex["unpaired_104"]), (3, 0, 1, 2, 2, 1, 1))

    def test_an_answer_before_the_request_is_not_its_answer(self):
        ex = M.exchanges([f(50, "A-B", "A", 104, input_block_id="x", count=1)],
                         [f(100, "A-B", "B", 105, input_block_id="x", count=1, weak_ids=["01" * 6])])
        self.assertEqual((ex["unanswered"], ex["unpaired_104"]), (1, 1))

    def test_unlisted_payment(self):
        self.assertEqual(M.per_payment(PAYS[:1], [], [])[0]["path"], "unlisted")


class Runs(unittest.TestCase):
    def test_hops_are_split_by_link_and_direction(self):
        msgs = [f(10, "A-B", "A", 100, input_block_id="i", weak_tx_ids=1, weak_ids=["aa11bb000000"]),
                f(20, "A-B", "B", 100, input_block_id="i", weak_tx_ids=1, weak_ids=["aa11bb000000"]),
                f(30, "B-C", "B", 100, input_block_id="i", weak_tx_ids=1, weak_ids=["aa11bb000000"])]
        with tempfile.TemporaryDirectory() as d:
            r = M.per_run(run_dir(d, "fix-d150-1", msgs, PAYS[:1]))
        self.assertEqual((r["hops"]["A->B"]["input_blocks"], r["hops"]["B->C"]["input_blocks"]), (1, 1))
        self.assertEqual((r["hops"]["A->B"]["rows"][0]["listed_ms"], r["hops"]["B->C"]["rows"][0]["listed_ms"]), (10, 30))

    def test_capture_loss_in_either_direction_leaves_the_run_out_of_the_pool(self):
        ok = [f(10, "A-B", "A", 100, input_block_id="i", weak_tx_ids=1, weak_ids=["aa11bb000000"])]
        with tempfile.TemporaryDirectory() as d:
            a = run_dir(d, "fix-d0-1", ok, PAYS[:1])
            b = run_dir(d, "fix-d0-2", ok + [{"kind": "gap", "link": "B-C", "from": "C", "t_ms": 5, "bytes": 9}], PAYS[:1])
            buf = io.StringIO()
            with contextlib.redirect_stdout(buf):
                M.main([a, b])
        out = buf.getvalue()
        self.assertIn("fix-d0-2: 1 payments EXCLUDED from the pool: 1 capture gap(s)", out)
        self.assertIn("ARM fix-d0 A->B payments listed in an input block 1/1", out)

    def test_confirmed_payments_listed_or_not(self):
        with tempfile.TemporaryDirectory() as d:
            r = run_dir(d, "fix-d0-1", [f(10, "A-B", "A", 100, input_block_id="i", weak_tx_ids=1, weak_ids=["aa11bb000000"])], PAYS)
            with open(os.path.join(r, "confirmed.jsonl"), "w") as fh:
                fh.write(json.dumps({"id": P2, "height": 9}) + "\n")
            buf = io.StringIO()
            with contextlib.redirect_stdout(buf):
                M.main([r])
        self.assertIn("fix-d0-1: 2 payments; confirmed on C 1/2, of them in no input block on A->B 1; unconfirmed 1", buf.getvalue())


if __name__ == "__main__":
    unittest.main()
