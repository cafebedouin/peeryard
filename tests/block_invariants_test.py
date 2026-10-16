"""Unit tests for diag/block_invariants.py: a clean chain passes every check, each generic check reports the one
violation seeded for it, and the deliberately failing contract check (rig/lib/invariants/deliberate-fail.sh) is reported
on every block. Run: python3 -m unittest tests/block_invariants_test.py"""
import copy
import io
import json
import os
import sys
import tempfile
import unittest
from contextlib import redirect_stdout

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "diag"))
import block_invariants as bi  # noqa: E402

FAIL_CHECK = os.path.join(HERE, "..", "rig", "lib", "invariants", "deliberate-fail.sh")


def bid(h, fork=""):
    return ("%s%x" % (fork, h)).rjust(64, "0")


def tx(name):
    return name.ljust(64, "0")


def block(h, fork="", txs=None, parent=None):
    return {"header": {"id": bid(h, fork), "height": h, "parentId": parent or (bid(h - 1, fork) if h > 1 else "0" * 64)},
            "blockTransactions": {"transactions": [{"id": t} for t in (txs if txs is not None else [tx(f"cb{h}")])]}}


def chain(nodes=("A", "B"), top=8, t0=1000):
    recs, t = [], t0
    for h in range(1, top + 1):
        for n in nodes:
            t += 1
            b = block(h, txs=[tx(f"cb{h}")] + ([tx("pay1")] if h == 4 else []))
            recs.append({"t_ms": t, "node": n, "h": h, "id": b["header"]["id"], "block": b})
    for n in nodes:
        t += 1
        recs.append({"t_ms": t, "node": n, "ev": "pool", "h": top, "ids": [tx("pending")]})
    return recs


def run(recs, *args):
    d = tempfile.mkdtemp(); p = os.path.join(d, "blocks.jsonl")
    with open(p, "w") as f:
        for r in recs:
            f.write(json.dumps(r) + "\n")
    out = io.StringIO()
    with redirect_stdout(out):
        rc = bi.main([p, "--json", os.path.join(d, "inv.json")] + list(args))
    with open(os.path.join(d, "inv.json")) as f:
        js = json.load(f)
    return rc, out.getvalue(), js


def count(js, k):
    return len(js["violations"].get(k, []))


class Clean(unittest.TestCase):
    def test_clean_chain_passes(self):
        rc, out, js = run(chain())
        self.assertEqual(rc, 0, out)
        self.assertIn("INVARIANTS: OK blocks=8 nodes=2 pools=2", out)

    def test_no_input(self):
        d = tempfile.mkdtemp()
        with redirect_stdout(io.StringIO()):
            self.assertEqual(bi.main([os.path.join(d, "none.jsonl")]), 2)

    def test_reorg_is_not_a_violation(self):
        recs = chain(nodes=("A",), top=6)
        # A first held a sibling at 6, then the block it ended on: two records at 6, the final one links to 5
        sib = block(6, fork="f", parent=bid(5))
        recs.insert(-1, {"t_ms": 1, "node": "A", "h": 6, "id": sib["header"]["id"], "block": sib})
        rc, out, _ = run(recs)
        self.assertEqual(rc, 0, out)


class EachCheckReports(unittest.TestCase):
    def test_link(self):
        recs = chain()
        r = next(x for x in recs if x.get("node") == "B" and x.get("h") == 5)
        r["block"] = block(5, parent=bid(9, "e"))
        rc, out, js = run(recs)
        self.assertEqual((rc, count(js, "link")), (1, 1), out)
        self.assertIn("link B@5", out)

    def test_body_empty_and_duplicate(self):
        recs = chain()
        next(x for x in recs if x.get("node") == "A" and x.get("h") == 2)["block"] = block(2, txs=[])
        next(x for x in recs if x.get("node") == "A" and x.get("h") == 3)["block"] = block(3, txs=[tx("d"), tx("d")])
        rc, out, js = run(recs)
        self.assertEqual(count(js, "body"), 2, out)

    def test_once(self):
        recs = chain()
        next(x for x in recs if x.get("node") == "A" and x.get("h") == 6)["block"] = block(6, txs=[tx("cb6"), tx("pay1")])
        rc, out, js = run(recs)
        self.assertEqual(count(js, "once"), 1, out)
        self.assertIn("already in the block at 4", out)

    def test_pool(self):
        recs = chain()
        next(x for x in recs if x.get("ev") == "pool" and x["node"] == "B")["ids"].append(tx("pay1"))
        rc, out, js = run(recs)
        self.assertEqual(count(js, "pool"), 1, out)
        self.assertIn("still in the pool", out)

    def test_pool_lag_spares_the_tip(self):
        recs = chain()
        next(x for x in recs if x.get("ev") == "pool")["ids"].append(tx("cb8"))   # the tip's own transaction
        rc, out, js = run(recs)
        self.assertEqual(count(js, "pool"), 0, out)

    def test_agree(self):
        recs = chain(nodes=("A", "B"), top=10)
        for x in recs:
            if x.get("node") == "B" and x.get("h", 0) >= 3:
                x["block"] = block(x["h"], fork="b"); x["id"] = x["block"]["header"]["id"]
        rc, out, js = run(recs)
        self.assertEqual(count(js, "agree"), 5, out)                  # heights 3..7 (tip 10, depth 3)
        self.assertEqual(count(js, "link"), 1, out)                   # the seeded fork's first block names a parent B never held at 2
        self.assertIn("agree A,B@3", out)


class Contract(unittest.TestCase):
    def test_deliberate_fail_is_reported_on_every_block(self):
        rc, out, js = run(chain(), "--contract", FAIL_CHECK)
        self.assertEqual(rc, 1)
        self.assertEqual(count(js, "contract:deliberate-fail.sh"), 8)  # once per distinct block, not per node
        self.assertIn("deliberate test failure at height 1", out)
        self.assertIn("INVARIANTS: VIOLATED total=8", out)
        self.assertEqual(sum(count(js, k) for k in ("link", "body", "once", "pool", "agree")), 0)

    def test_deliberate_fail_every_third_height(self):
        os.environ["DELIBERATE_FAIL_EVERY"] = "3"
        try:
            rc, out, js = run(chain(), "--contract", FAIL_CHECK)
        finally:
            del os.environ["DELIBERATE_FAIL_EVERY"]
        self.assertEqual([v["h"] for v in js["violations"]["contract:deliberate-fail.sh"]], [3, 6])

    def test_contract_gets_the_block(self):
        d = tempfile.mkdtemp(); c = os.path.join(d, "two-txs.sh")
        with open(c, "w") as f:
            f.write('#!/usr/bin/env bash\nn=$(jq ".blockTransactions.transactions | length")\n'
                    '[[ $n -le 1 ]] || { echo "$BLOCK_NODE $BLOCK_HEIGHT has $n transactions"; exit 1; }\n')
        os.chmod(c, 0o755)
        rc, out, js = run(chain(), "--contract", c)
        self.assertEqual([v["h"] for v in js["violations"]["contract:two-txs.sh"]], [4], out)

    def test_missing_contract_command_is_a_violation_not_a_crash(self):
        rc, out, js = run(chain(nodes=("A",), top=2), "--contract", "/nonexistent/check")
        self.assertEqual(count(js, "contract:check"), 2)


if __name__ == "__main__":
    unittest.main()
