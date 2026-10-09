"""Unit tests for diag/matrix_value.py: the uncle value split (duplicate / unique) and the sibling fates on a synthetic
input-block tree, frame bytes and groups, and the BlockTransactions request matcher on the golden capture (a reference
node's routine section download: every delivered header's transactions are requested). Run:
python3 -m unittest tests/matrix_value_test.py"""
import json
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "diag"))
import matrix_value as mv  # noqa: E402
import wire  # noqa: E402

O = "0" * 64


def blk(i, t, prev, weak, uncles=(), frm="A"):
    return {"t_ms": t, "from": frm, "ord": O, "prev": prev, "weak": list(weak), "uncles": list(uncles), "version": 2}


def tree(with_uncle):
    a1, a2, a3, s, b1 = "a1" * 32, "a2" * 32, "a3" * 32, "5e" * 32, "b1" * 32
    ib = {a1: blk(a1, 10, None, ["aa0000000001", "aa0000000002"]),
          a2: blk(a2, 20, a1, ["aa0000000003"]),
          s: blk(s, 21, a1, ["aa0000000003", "bb0000000004", "cc0000000006"], frm="B"),          # sibling of a2
          a3: blk(a3, 30, a2, ["aa0000000005"], uncles=[s] if with_uncle else [])}
    ib[b1] = dict(blk(b1, 40, None, ["cc0000000006"]), ord="1" * 64)          # cc...06 re-included under the next ordering block
    return ib, s


class Value(unittest.TestCase):
    def test_uncle_split_into_duplicates_and_unique(self):
        ib, s = tree(True)
        v = mv.value_section(ib, {}, {"bb0000000004" + "0" * 60}, set(), {O}, 0, 100)
        m = v["merged_uncles"]
        self.assertEqual((m["merges"], m["uncle_txs"], m["duplicates"], m["unique"]), (1, 3, 1, 2))
        self.assertEqual(m["unique_payments"], 1)          # bb0000... matches a payment id by its first 3 bytes
        self.assertEqual(v["siblings"]["transactions"], {"txs": 3, "on_winning_path": 1, "recovered_by_merge": 2})

    def test_without_uncles_the_same_sibling_is_re_included_or_lost(self):
        ib, s = tree(False)
        v = mv.value_section(ib, {}, set(), {"cc0000" + "2" * 58}, {O}, 0, 100)
        self.assertEqual(v["merged_uncles"]["merges"], 0)
        self.assertEqual(v["siblings"]["transactions"],
                         {"txs": 3, "on_winning_path": 1, "re_included_later": 1, "in_no_other_input_block": 1,
                          "not_merged_but_on_final_chain": 1})

    def test_uncle_with_unknown_transactions_is_counted_not_guessed(self):
        ib, s = tree(True)
        ib[s]["weak"] = None
        v = mv.value_section(ib, {}, set(), set(), {O}, 0, 100)
        self.assertEqual((v["merged_uncles"]["merges"], v["merged_uncles"]["uncles_without_known_txs"]), (0, 1))

    def test_weak_ids_checked_against_full_ids(self):
        ib, _ = tree(True)
        a1 = "a1" * 32
        ib[a1]["weak"] = ["abcdef111111", "123456222222"]
        v = mv.value_section(ib, {a1: ["123456" + "9" * 58, "abcdef" + "8" * 58]}, set(), set(), {O}, 0, 100)
        self.assertEqual(v["weak_vs_full_ids"], {"compared": 1, "agree": 1})


class Wire(unittest.TestCase):
    def test_frame_bytes_and_groups(self):
        self.assertEqual(mv.frame_bytes({"len": 0}), 9)
        self.assertEqual(mv.frame_bytes({"len": 100}), 113)
        g = {(100, None): "input-block", (55, -123): "input-block", (102, None): "input-block-txids",
             (105, None): "input-block-txs", (106, None): "ordering-announce", (22, 102): "block-transactions",
             (33, 101): "block-sections-other", (55, 2): "transactions", (65, None): "sync", (1, None): "other"}
        for (code, tid), want in g.items():
            self.assertEqual(mv.group_of({"code": code, "type_id": tid}), want, (code, tid))

    def test_requests_matched_on_the_golden_capture(self):
        fx = os.path.join(os.path.dirname(__file__), "fixtures")
        with open(os.path.join(fx, "wire-bringup.json")) as fh:
            meta = json.load(fh)
        recs, _ = wire.decode_pcap(os.path.join(fx, "wire-bringup.pcap"), "A-B", bytes(meta["magic"]), meta["names"])
        frames = [r for r in recs if r["kind"] == "frame"]
        out = mv.requests_wire(frames, 0, 1 << 62)
        # B, the follower, requested the transactions of each of the 5 blocks whose header it got on this capture;
        # its other type-102 requests name blocks whose header delivery the capture does not hold (unmatched)
        b = out["B"]
        self.assertEqual((b["ordering_blocks_received"], b["with_tx_request_sent"]), (5, 5))
        headers = {i for r in frames if r.get("code") == 33 and r.get("type_id") == 101 for i in r["modifier_ids"]}
        req101 = {i for r in frames if r.get("code") == 22 and r.get("type_id") == 101 and r["from"] == "B"
                  for i in r["modifier_ids"]}
        self.assertEqual(b["type102_requests_unmatched"], len(req101 - headers))


if __name__ == "__main__":
    unittest.main()
