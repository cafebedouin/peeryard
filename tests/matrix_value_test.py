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

    def test_header_kind_credits_and_never_recovers(self):
        # the same tree under header semantics: the reference is credit only, the sibling's txs are not collected
        ib, s = tree(True)
        v = mv.value_section(ib, {}, set(), {"cc0000" + "2" * 58}, {O}, 0, 100, kind="header")
        m = v["merged_uncles"]
        self.assertEqual((m["references"], m["uncle_txs"], m["already_on_referencing_chain"], m["not_on_referencing_chain"]),
                         (1, 3, 1, 2))
        self.assertNotIn("unique", m)
        t = v["siblings"]["transactions"]
        self.assertEqual(t, {"txs": 3, "on_winning_path": 1, "re_included_later": 1, "in_no_other_input_block": 1,
                             "not_merged_but_on_final_chain": 1})
        self.assertEqual(v["siblings"]["blocks"], {"siblings": 1, "credited": 1})
        self.assertEqual(v["siblings"]["re_inclusion_delay_ms"], {"n": 1, "p50": 19, "p90": 19})

    def test_kind_detection(self):
        ib, _ = tree(True)
        self.assertEqual(mv.uncles_kind(ib, [{"ev": "input", "credited": ["x"]}]), "header")
        self.assertEqual(mv.uncles_kind(ib, [{"ev": "input", "credited": "absent"}]), "merging")
        self.assertEqual(mv.uncles_kind(ib, [{"ev": "input"}]), "merging")
        ib2, _ = tree(False)
        self.assertEqual(mv.uncles_kind(ib2, []), "none")

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


class Nodes(unittest.TestCase):
    def test_flag_state_credit_invalid_and_penalties(self):
        L = {"invalid": [5, 6], "double": [5, 6, 7], "penalties": [(5, "100.64.0.2", "MisbehaviorPenalty")]}
        watch = [{"ev": "input", "node": "A", "t_ms": 5, "credited": ["u1", "u2"]},
                 {"ev": "input", "node": "A", "t_ms": 6, "credited": []},
                 {"ev": "input", "node": "C", "t_ms": 5, "credited": "absent"},
                 {"ev": "full", "node": "A", "t_ms": 7, "h": 9, "id": "x"},
                 {"ev": "full", "node": "C", "t_ms": 7, "h": 9, "id": "x"}]
        eff = {"nodes": [{"name": "A", "id_ip": "100.64.0.1", "conf": {}},
                         {"name": "B", "id_ip": "100.64.0.2"},
                         {"name": "C", "id_ip": "100.64.0.3", "conf": {"ergo.node.inputBlockUncles": "false"}}]}
        out = mv.nodes_section({"A": L}, watch, eff, "[matrix-compat] A-C same_chain=SAME@9:x", 0, 100)
        a, c = out["per_node"]["A"], out["per_node"]["C"]
        self.assertEqual((a["inputBlockUncles_conf"], a["credited_field"], a["blocks_with_credit"], a["credited_refs"]),
                         ("jar default", "reported", 1, 2))
        self.assertEqual((a["permanently_invalid"], a["double_application"], a["penalties_given"]),
                         (2, 3, {"B:MisbehaviorPenalty": 1}))
        self.assertEqual((c["inputBlockUncles_conf"], c["credited_field"], c["same_chain_as_A"]), ("false", "absent", "SAME@9:x"))
        self.assertTrue(out["final_tips_agree"])

    def test_continuation_line_double_application_is_counted(self):
        import tempfile
        with tempfile.NamedTemporaryFile("w", suffix=".log", delete=False) as fh:
            fh.write("05:26:46.100 WARN  [x] o.e.n.ErgoNodeViewSynchronizer - Modifier aa is permanently invalid\n"
                     "org.ergoplatform.validation.MalformedModifierError: Double application of a modifier is prohibited. aa\n"
                     "\tat somewhere\n"
                     "05:26:46.200 INFO  [x] o.e.n.peer.PeerManager - /100.64.0.2:49900 penalized, penalty: MisbehaviorPenalty\n")
        r = mv.scan_log(fh.name, mv.Clock(1791520000000))
        os.unlink(fh.name)
        self.assertEqual((len(r["invalid"]), len(r["double"]), [p[1:] for p in r["penalties"]]),
                         (1, 1, [("100.64.0.2", "MisbehaviorPenalty")]))


class Credit(unittest.TestCase):
    def test_agreement_across_flag_on_nodes(self):
        w = [{"ev": "input", "node": "A", "t_ms": 1, "id": "b1", "credited": ["u1"]},
             {"ev": "input", "node": "B", "t_ms": 2, "id": "b1", "credited": ["u1"]},
             {"ev": "input", "node": "A", "t_ms": 3, "id": "b2", "credited": ["u2"]},
             {"ev": "input", "node": "B", "t_ms": 4, "id": "b2", "credited": []},
             {"ev": "input", "node": "A", "t_ms": 5, "id": "b3", "credited": []},
             {"ev": "input", "node": "B", "t_ms": 6, "id": "b3", "credited": []},
             {"ev": "input", "node": "C", "t_ms": 6, "id": "b3", "credited": "absent"},   # flag off: not compared
             {"ev": "input", "node": "A", "t_ms": 7, "id": "b4", "credited": ["u4"]},     # one node only
             {"ev": "input", "node": "A", "t_ms": 8, "id": "b1", "credited": []}]         # later sighting ignored
        ca = mv.credit_agreement(w, 0, 100)
        self.assertEqual((ca["blocks_on_2plus_nodes"], ca["identical"], ca["disagree"], ca["of_which_with_any_credit"]),
                         (3, 2, 1, 2))
        self.assertEqual(ca["example"], {"input_block": "b2", "credited": {"A": ["u2"], "B": []}})
        self.assertEqual(ca["identical_share_among_credited"], 0.5)

    def test_no_flag_on_node(self):
        self.assertTrue(mv.credit_agreement([{"ev": "input", "node": "C", "t_ms": 1, "id": "x", "credited": "absent"}],
                                            0, 10).startswith("n/a"))


class BodyRequests(unittest.TestCase):
    def test_answered_unanswered_fate_flag_and_rerequest(self):
        ib, s = tree(True)                      # a1 <- a2 <- a3 (best path), s = sibling of a2, b1 under another O
        a2 = "a2" * 32
        b1 = "b1" * 32
        F = [  # C (flag off) asks A for the sibling's tx ids: no answer; then asks B, which answers 40 ms later
            {"code": 22, "type_id": -122, "from": "C", "to": "A", "t_ms": 100, "modifier_ids": [s]},
            {"code": 22, "type_id": -122, "from": "C", "to": "B", "t_ms": 200, "modifier_ids": [s]},
            {"code": 102, "from": "B", "to": "C", "t_ms": 240, "input_block_id": s},
            # A (flag on) asks C for specific transactions of a best-chain block; C answers 10 ms later
            {"code": 105, "from": "A", "to": "C", "t_ms": 300, "input_block_id": a2},
            {"code": 104, "from": "C", "to": "A", "t_ms": 310, "input_block_id": a2},
            # an answer that precedes its request does not count; b1's ordering block is not final -> "other"
            {"code": 104, "from": "A", "to": "B", "t_ms": 390, "input_block_id": b1},
            {"code": 105, "from": "B", "to": "A", "t_ms": 400, "input_block_id": b1}]
        out = mv.body_requests(F, ib, {O}, {"A": "on", "B": "on", "C": "off"}, 1000)
        c, a, b = out["C"], out["A"], out["B"]
        self.assertEqual((c["flag"], c["requests"], c["answered"], c["unanswered"]),
                         ("off", {"txids/sibling": 2}, {"txids/sibling": 1}, {"txids/sibling": 1}))
        self.assertEqual((c["sibling_body_requests"], c["re_requests_other_peer"]), (2, 1))
        self.assertEqual(c["latency_ms"]["txids"], {"n": 1, "p50": 40, "p90": 40, "max": 40})
        self.assertEqual((a["requests"], a["answered"], a["latency_ms"]["txs"]["p50"]), ({"txs/best": 1}, {"txs/best": 1}, 10))
        self.assertEqual((b["requests"], b["unanswered"]), ({"txs/other": 1}, {"txs/other": 1}))
        self.assertEqual(c["unanswered_examples"][0]["to"], "A")


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
