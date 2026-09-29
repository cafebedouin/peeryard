#!/usr/bin/env python3
"""Tests for diag/diagnose.py: the ConvergenceDiagnosis spec, case for case. No nodes: the classifier is a pure function
of sampled state. End states marked CI are ones upstream's own integration runs ended in (run ids in the comments).

  python3 tests/diagnose_test.py
"""
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "diag"))
import diagnose as D  # noqa: E402


def node(name, headers, full, header_id, full_id, peers=1, mining=False, state=D.RUNNING, at=0):
    return D.NodeSample(name, at, state, True, headers, full, header_id, full_id, peers, mining)


def silent(name, state=D.RUNNING, at=0):
    return D.NodeSample(name, at, state, False, None, None, None, None, None, None)


def frozen(rnd, rounds=5):
    """The same round seen `rounds` times, ten seconds apart (the 30 s spans are covered): nothing moved."""
    return [[D.NodeSample(**{**n.__dict__, "at": i * 10_000}) for n in rnd] for i in range(rounds)]


def at(n, t):
    return D.NodeSample(**{**n.__dict__, "at": t})


class DiagnoseSpec(unittest.TestCase):
    def test_tie(self):
        # CI 35356023528, 35522217646, 35522895591 (DeepRollBackSpec): A 231/231, B 231/231, different tips
        d = D.diagnose(frozen([node("A", 231, 231, "09edb3f9", "09edb3f9"), node("B", 231, 231, "c718c331", "c718c331")]))
        self.assertEqual(d.cause, D.EQUAL_HEIGHT_TIE)
        self.assertIn("mining=off", d.evidence)

    def test_headers_ahead(self):
        # CI 35579493804 (DeepRollBackSpec): B has A's 260 headers, full height stays at 70 on its own fork
        d = D.diagnose(frozen([node("A", 260, 260, "a377fa9e", "a377fa9e"), node("B", 260, 70, "a377fa9e", "19dd9a76")]))
        self.assertEqual(d.cause, D.HEADERS_AHEAD_FULL_STUCK)
        self.assertIn("B[running] headers=260:a377fa9e full=70:19dd9a76", d.evidence)

    def test_lighter_fork_not_switching(self):
        # CI 34744409218, 34745269264 (DeepRollBackSpec): A 249/249, B 70/70, one peer each
        d = D.diagnose(frozen([node("A", 249, 249, "c1c00bf0", "c1c00bf0"), node("B", 70, 70, "a8eae678", "a8eae678")]))
        self.assertEqual(d.cause, D.LIGHTER_FORK_NOT_SWITCHING)
        self.assertIn("B[running]", d.evidence)

    def test_stalled(self):
        self.assertEqual(D.diagnose(frozen([node("A", 12, 12, "aa", "aa"), node("B", 12, 12, "aa", "aa")])).cause,
                         D.CHAIN_STALLED)

    def test_infrastructure_wins(self):
        tie = [node("A", 5, 5, "aa", "aa"), node("B", 5, 5, "bb", "bb")]
        self.assertEqual(D.diagnose(frozen([tie[0], silent("B", "exited(137)")])).cause, D.NODE_DOWN)
        # one unanswered state probe proves nothing
        self.assertNotEqual(D.diagnose(frozen(tie, 4) + [[tie[0], silent("B", D.UNKNOWN_STATE, at=40_000)]]).cause,
                            D.NODE_DOWN)
        self.assertIn("oom-killed", D.diagnose(frozen([tie[0], silent("B", "oom-killed")])).evidence)
        self.assertEqual(D.diagnose(frozen([tie[0], silent("B")])).cause, D.NODE_UNRESPONSIVE)
        self.assertEqual(D.diagnose(frozen([tie[0], node("B", 5, 5, "bb", "bb", peers=0)])).cause, D.NO_PEERS)

    def test_isolation_on_purpose(self):
        isolated = [node("A", 5, 5, "aa", "aa", peers=0), node("B", 5, 5, "aa", "aa", peers=0)]
        self.assertEqual(D.diagnose(frozen(isolated)).cause, D.NO_PEERS)
        self.assertEqual(D.diagnose(frozen(isolated), expect_peers=False).cause, D.CHAIN_STALLED)

    def test_full_stuck_while_headers_advance(self):
        # B takes A's headers but its full height never moves: the live form of CI 35579493804
        history = [[node("A", 100 + i, 100 + i, f"a{i}", f"a{i}", at=i * 1000),
                    node("B", 100 + i, 70, f"a{i}", "b70", at=i * 1000)] for i in range(41)]
        self.assertEqual(D.diagnose(history).cause, D.HEADERS_AHEAD_FULL_STUCK)

    def test_early_progress_does_not_hide_stall(self):
        early = [[node("A", 10 + i, 10 + i, f"a{i}", f"a{i}", at=i * 1000),
                  node("B", 10 + i, 10 + i, f"a{i}", f"a{i}", at=i * 1000)] for i in range(4)]
        stalled = [[node("A", 13, 13, "a3", "a3", at=i * 1000), node("B", 13, 13, "a3", "a3", at=i * 1000)]
                   for i in range(4, 61)]
        self.assertEqual(D.diagnose(early + stalled).cause, D.CHAIN_STALLED)

    def test_silent_node_not_negative_progress(self):
        history = [[node("A", 10 + i, 10 + i, f"a{i}", f"a{i}", at=i * 1000),
                    node("B", 10 + i, 10 + i, f"a{i}", f"a{i}", at=i * 1000) if i < 35 else silent("B", at=i * 1000)]
                   for i in range(41)]
        self.assertEqual(D.diagnose(history).cause, D.NODE_UNRESPONSIVE)
        d = D.diagnose(history[:35][-31:])
        self.assertEqual(d.cause, D.STILL_PROGRESSING)
        self.assertNotIn("(-", d.evidence)

    def test_paused_is_unresponsive(self):
        d = D.diagnose(frozen([node("A", 5, 5, "aa", "aa"), silent("B", D.PAUSED)]))
        self.assertEqual(d.cause, D.NODE_UNRESPONSIVE)
        self.assertIn("B[paused]", d.evidence)

    def test_idle_height_zero_is_stalled(self):
        idle = [D.NodeSample(n, 0, D.RUNNING, True, None, None, None, None, 1, False) for n in ("A", "B")]
        self.assertEqual(D.diagnose(frozen(idle)).cause, D.CHAIN_STALLED)

    def test_lagging_with_peers_listed(self):
        history = [[node("A", 10 + i, 10 + i, f"a{i}", f"a{i}", at=i * 1000),
                    node("B", 12, 12, "b", "b", peers=2, at=i * 1000)] for i in range(41)]
        d = D.diagnose(history)
        self.assertEqual(d.cause, D.NODE_LAGGING)
        self.assertIn("B[running]", d.evidence)

    def test_not_lagging_when_group_gained_little(self):
        history = [[node("A", 10 + i // 20, 10 + i // 20, "a", "a", at=i * 1000), node("B", 10, 10, "a", "a", at=i * 1000)]
                   for i in range(41)]
        self.assertNotEqual(D.diagnose(history).cause, D.NODE_LAGGING)

    def test_one_unanswered_round_is_not_a_cause(self):
        ok = [node("A", 5, 5, "aa", "aa"), node("B", 5, 5, "aa", "aa")]
        history = frozen(ok, 4) + [[node("A", 5, 5, "aa", "aa", at=40_000), silent("B", at=40_000)]]
        self.assertNotEqual(D.diagnose(history).cause, D.NODE_UNRESPONSIVE)

    def test_525(self):
        d = D.diagnose(frozen([node("A", 9, 9, "aa", "aa"), node("B", 9, 9, "aa", "bb")]))
        self.assertEqual(d.cause, D.BEST_CHAIN_INCONSISTENT)
        self.assertIn("B[running]", d.evidence)

    def test_525_not_named_while_only_lagging(self):
        self.assertNotEqual(D.diagnose(frozen([node("A", 9, 9, "aa", "aa"), node("B", 9, 8, "aa", "bb")])).cause,
                            D.BEST_CHAIN_INCONSISTENT)

    def test_still_progressing_with_rate(self):
        history = [[node("A", 10 + i, 10 + i, f"a{i}", f"a{i}", at=i * 1000),
                    node("B", 10 + i, 9 + i, f"a{i}", f"b{i}", at=i * 1000)] for i in range(5)]
        d = D.diagnose(history)
        self.assertEqual(d.cause, D.STILL_PROGRESSING)
        self.assertIn("blocks/min", d.evidence)

    def test_no_samples(self):
        self.assertEqual(D.diagnose([]).cause, D.UNKNOWN)
        self.assertIn("CAUSE UNKNOWN", D.report([], "goal"))



def ev(kind, t, a=None, b=None, node=None):
    return {"t": t, "kind": kind, "a": a, "b": b, "node": node, "detail": None}


class Partitioned(unittest.TestCase):
    lonely = frozen([node("A", 30, 30, "aa", "aa", peers=1, mining=True), node("B", 20, 20, "bb", "bb", peers=0),
                     node("C", 30, 30, "aa", "aa", peers=1)])

    def test_a_node_cut_on_every_link_is_partitioned_and_the_samples_cause_is_kept(self):
        links = [("A", "B"), ("A", "C")]
        events = [ev("launch", 0, node="A"), ev("partition", 5, "A", "B"), ev("relaunch", 9, node="B")]
        d = D.diagnose(self.lonely, events=events, links=links)
        self.assertEqual((d.cause, d.observed), (D.PARTITIONED, D.NO_PEERS))
        self.assertTrue(d.evidence.startswith("B cut from every peer"))
        self.assertEqual(d.as_json()["observed"], D.NO_PEERS)

    def test_event_order_of_a_and_b_does_not_matter(self):
        self.assertEqual(D.partitioned([ev("partition", 1, "B", "A")], [("A", "B")]), ["A", "B"])

    def test_a_later_heal_ends_the_cut(self):
        events = [ev("partition", 1, "A", "B"), ev("heal", 2, "B", "A")]
        self.assertEqual(D.partitioned(events, [("A", "B")]), [])
        self.assertEqual(D.partitioned(events + [ev("partition", 3, "A", "B")], [("A", "B")]), ["A", "B"])

    def test_one_live_link_left_is_not_partitioned(self):
        # A-B cut, A-C live: only B lost every peer
        self.assertEqual(D.partitioned([ev("partition", 1, "A", "B")], [("A", "B"), ("A", "C")]), ["B"])

    def test_no_peers_positive_control(self):
        # a node started with no peers and never cut stays NO_PEERS: the event rule does not swallow it
        events = [ev("launch", 0, node="A"), ev("launch", 0, node="B"), ev("launch", 0, node="C")]
        d = D.diagnose(self.lonely, events=events, links=[("A", "C")])
        self.assertEqual((d.cause, d.observed), (D.NO_PEERS, None))

    def test_without_events_nothing_changes(self):
        self.assertEqual(D.diagnose(self.lonely).cause, D.NO_PEERS)


def msg(t, frm, to, name, type_id=None, kind="frame", link="L-S"):
    m = {"t_ms": t, "kind": kind, "link": link, "conn": 1, "from": frm, "to": to}
    if kind == "frame":
        m.update(name=name, code={"SyncInfo": 65, "Inv": 55, "RequestModifier": 22, "Modifiers": 33}[name])
        if type_id is not None:
            m["type_id"] = type_id
    return m


class WireSplit(unittest.TestCase):
    # L stuck at 10 on its own fork from t=20 s; S at 20 on the heavier one. Frames at t < 20 s are outside the window.
    hist = [[node("L", 9, 9, "l9", "l9", at=i * 10_000), node("S", 20, 20, "s20", "s20", at=i * 10_000)] for i in range(2)] + \
           [[node("L", 10, 10, "l10", "l10", at=i * 10_000), node("S", 20, 20, "s20", "s20", at=i * 10_000)]
            for i in range(2, 7)]
    early = [msg(1_000, "S", "L", "Inv", 101), msg(1_100, "L", "S", "RequestModifier", 101),
             msg(1_200, "S", "L", "Modifiers", 101)]   # before L's last height change: not counted

    def split(self, msgs, drops=None):
        d = D.diagnose(self.hist, messages=self.early + msgs, drop_seconds={"L-S": []} if drops is None else drops)
        self.assertEqual(d.cause, D.LIGHTER_FORK_NOT_SWITCHING)
        (w,) = d.wire
        return w

    def test_no_sync(self):
        self.assertEqual(self.split([])["stage"], D.NO_SYNC)

    def test_sync_no_inv(self):
        self.assertEqual(self.split([msg(30_000, "L", "S", "SyncInfo")])["stage"], D.SYNC_NO_INV)

    def test_inv_not_requested(self):
        w = self.split([msg(30_000, "L", "S", "SyncInfo"), msg(30_100, "S", "L", "Inv", 101)])
        self.assertEqual(w["stage"], D.INV_NOT_REQUESTED)

    def test_request_not_answered(self):
        w = self.split([msg(30_000, "S", "L", "SyncInfo"), msg(30_100, "S", "L", "Inv", 101),
                        msg(30_200, "L", "S", "RequestModifier", 101)])
        self.assertEqual(w["stage"], D.REQUEST_NOT_ANSWERED)

    def test_delivered_no_height_change(self):
        w = self.split([msg(30_000, "L", "S", "SyncInfo"), msg(30_100, "S", "L", "Inv", 108),
                        msg(30_200, "L", "S", "RequestModifier", 108), msg(30_300, "S", "L", "Modifiers", 108)])
        self.assertEqual((w["stage"], w["counts"]), (D.DELIVERED_NO_HEIGHT_CHANGE,
                                                     {"sync": 1, "inv_back": 1, "request": 1, "modifiers_back": 1}))

    def test_transactions_never_advance_the_ladder(self):
        w = self.split([msg(30_000, "L", "S", "SyncInfo"), msg(30_100, "S", "L", "Inv", 2),
                        msg(30_200, "L", "S", "RequestModifier", 2), msg(30_300, "S", "L", "Modifiers", 2)])
        self.assertEqual(w["stage"], D.SYNC_NO_INV)

    def test_direction_matters(self):
        # an Inv from the lower node, a request from the higher one: neither is the ladder's
        w = self.split([msg(30_000, "L", "S", "SyncInfo"), msg(30_100, "L", "S", "Inv", 101),
                        msg(30_200, "S", "L", "RequestModifier", 101)])
        self.assertEqual(w["stage"], D.SYNC_NO_INV)

    def test_missing_stats_is_unreliable(self):
        w = self.split([msg(30_000, "L", "S", "SyncInfo")], drops={})
        self.assertEqual((w["stage"], w["would_be"], w["links_without_stats"]), (D.UNRELIABLE, D.SYNC_NO_INV, ["L-S"]))

    def test_gap_in_window_is_unreliable(self):
        w = self.split([msg(30_000, "L", "S", "SyncInfo"), msg(30_050, "S", "L", None, kind="gap")])
        self.assertEqual((w["stage"], w["would_be"]), (D.UNRELIABLE, D.SYNC_NO_INV))

    def test_drop_in_window_is_unreliable_and_before_it_is_not(self):
        m = [msg(30_000, "L", "S", "SyncInfo")]
        self.assertEqual(self.split(m, {"L-S": [40_000]})["stage"], D.UNRELIABLE)
        self.assertEqual(self.split(m, {"L-S": [5_000]})["stage"], D.SYNC_NO_INV)

    def test_partitioned_is_never_split_but_keeps_the_observed_cause(self):
        d = D.diagnose(self.hist, events=[ev("partition", 25_000, "L", "S")], links=[("L", "S")], messages=self.early)
        self.assertEqual((d.cause, d.observed, d.wire), (D.PARTITIONED, D.LIGHTER_FORK_NOT_SWITCHING, []))


if __name__ == "__main__":
    unittest.main(verbosity=1)
