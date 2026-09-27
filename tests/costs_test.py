"""Unit tests for diag/costs.py: each case against a hand-computed value. Run: python3 -m unittest tests/costs_test.py"""
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "diag"))
import costs  # noqa: E402

CLK = 100


def n(name, tip=None, answered=True, full=None, headers=None, pid=None, ticks=None, ms=None, timeout=False,
      mining=None, state="running", rss=None):
    return {"name": name, "answered": answered, "state": state, "bestFullHeaderId": tip if answered else None,
            "fullHeight": full if answered else None, "headersHeight": headers if answered else None, "pid": pid,
            "cpu_ticks": ticks, "loopback_info_ms": ms, "timeout": timeout, "mining": mining, "rss_mb": rss}


def row(t, *nodes, event=None):
    r = {"t": t, "nodes": list(nodes)}
    if event:
        r["event"] = event
    return r


def heal(t, a="A", b="B", detail=None):
    return {"t": t, "kind": "heal", "a": a, "b": b, "node": None, "detail": detail}


EFF = {"nodes": [{"name": "A", "mining": True}, {"name": "B", "mining": False}]}


def run(samples, events):
    return costs.compute(samples, events, EFF, CLK)


class AgreeS(unittest.TestCase):
    def test_1_agreement_at_sample_k(self):
        # heal at t=1000; regular samples at 3000 (differ), 6000 (equal), 9000 (equal): k = 6000 -> 5.0 s
        s = [row(1000, n("A", "x", full=5), n("B", "y", full=3), event="heal"),
             row(3000, n("A", "x"), n("B", "y")), row(6000, n("A", "z"), n("B", "z")), row(9000, n("A", "z"), n("B", "z"))]
        r = run(s, [heal(1000)])["recovery"][0]
        self.assertEqual(r["agree_s"], 5.0)
        self.assertFalse(r["censored"])
        self.assertEqual(r["height_gap"], 2)
        self.assertFalse(r["tips_equal_at_event"])

    def test_2_never_agrees_censored(self):
        s = [row(1000, n("A", "x"), n("B", "y"), event="heal"),
             row(3000, n("A", "x"), n("B", "y")), row(6000, n("A", "w"), n("B", "y"))]
        r = run(s, [heal(1000)])["recovery"][0]
        self.assertIsNone(r["agree_s"])
        self.assertTrue(r["censored"])
        self.assertEqual(r["reason"], "never_agreed")

    def test_4_k_plus_1_rule(self):
        # equal at 3000 but not at 6000; equal at 9000 and 12000 -> k = 9000 -> 8.0 s
        s = [row(1000, n("A", "x"), n("B", "y"), event="heal"),
             row(3000, n("A", "x"), n("B", "x")), row(6000, n("A", "q"), n("B", "x")),
             row(9000, n("A", "q"), n("B", "q")), row(12000, n("A", "q"), n("B", "q"))]
        self.assertEqual(run(s, [heal(1000)])["recovery"][0]["agree_s"], 8.0)

    def test_7_event_samples_left_out_of_the_series(self):
        # an event row with equal tips at 4000 (a mark's sample) must not count as k or k+1: k = 6000 -> 5.0 s
        s = [row(1000, n("A", "x"), n("B", "y"), event="heal"),
             row(3000, n("A", "z"), n("B", "z")), row(4000, n("A", "q"), n("B", "q"), event="mark"),
             row(6000, n("A", "q"), n("B", "q")), row(9000, n("A", "q"), n("B", "q"))]
        ev = [heal(1000), {"t": 3999, "kind": "mark", "a": None, "b": None, "node": None, "detail": "m"}]
        # 3000 is equal but 6000 differs from it (z vs q): 3000 fails the k+1 rule; k = 6000
        self.assertEqual(run(s, ev)["recovery"][0]["agree_s"], 5.0)

    def test_nothing_to_recover(self):
        s = [row(1000, n("A", "x"), n("B", "x"), event="heal"), row(3000, n("A", "x"), n("B", "x"))]
        r = run(s, [heal(1000)])["recovery"][0]
        self.assertEqual(r["status"], "nothing_to_recover")
        self.assertIsNone(r["agree_s"])

    def test_9_censor_reason_precedence(self):
        # a window closed by the next partition AND an unanswered sample: endpoint_down wins
        part = {"t": 7000, "kind": "partition", "a": "A", "b": "B", "node": None, "detail": None}
        s = [row(1000, n("A", "x"), n("B", "y"), event="heal"),
             row(3000, n("A", "x"), n("B", answered=False)), row(6000, n("A", "x"), n("B", "y")),
             row(9000, n("A", "x"), n("B", "x")), row(12000, n("A", "x"), n("B", "x"))]
        self.assertEqual(run(s, [heal(1000), part])["recovery"][0]["reason"], "endpoint_down")
        # all answered, closed by the partition: next_event (the agreement at 9000 lies outside the window)
        s[1] = row(3000, n("A", "x"), n("B", "y"))
        r = run(s, [heal(1000), part])["recovery"][0]
        self.assertEqual((r["reason"], r["closed_by"]), ("next_event", "partition"))
        # no closing event, never equal: never_agreed
        s2 = [row(1000, n("A", "x"), n("B", "y"), event="heal"), row(3000, n("A", "x"), n("B", "y"))]
        self.assertEqual(run(s2, [heal(1000)])["recovery"][0]["reason"], "never_agreed")

    def test_8_empty_window(self):
        # the next event on the link follows at once: no regular sample in the window
        s = [row(1000, n("A", "x"), n("B", "y"), event="heal")]
        ev = [heal(1000), {"t": 1500, "kind": "partition", "a": "A", "b": "B", "node": None, "detail": None}]
        r = run(s, ev)["recovery"][0]
        self.assertEqual((r["agree_s"], r["reason"]), (None, "next_event"))
        self.assertIsNone(r["per_node"]["A"]["cpu_s_in_window"])
        self.assertEqual(r["per_node"]["A"]["loopback_info_calls"], 0)


class Revive(unittest.TestCase):
    def test_revive_first_answer_sync_and_peer_max(self):
        ev = [{"t": 1000, "kind": "revive", "a": None, "b": None, "node": "B", "detail": None},
              {"t": 1100, "kind": "launch", "a": None, "b": None, "node": "B", "detail": None}]
        s = [row(1000, n("A", "x", full=20), n("B", answered=False, state="down"), n("C", "x", full=20), event="revive"),
             row(3000, n("A", "x", full=20), n("B", answered=False), n("C", "x", full=20)),
             row(6000, n("A", "x", full=20), n("B", "g", full=0), n("C", "x", full=20)),     # first answer, reloading
             row(9000, n("A", "x", full=20), n("B", "o", full=12), n("C", "x", full=20)),    # reference: first non-zero
             row(12000, n("A", "x", full=20), n("B", "x", full=20), n("C", "w", full=21)),   # agrees with A only
             row(15000, n("A", "x", full=20), n("B", "x", full=20), n("C", "w", full=21)),
             row(18000, n("A", "w", full=21), n("B", "w", full=21), n("C", "w", full=21)),
             row(21000, n("A", "w", full=21), n("B", "w", full=21), n("C", "w", full=21))]
        eff = {"nodes": [{"name": "A", "mining": True}, {"name": "B"}, {"name": "C"}]}
        r = costs.compute(s, ev, eff, CLK)["recovery"][0]
        self.assertEqual(r["first_answer_s"], 5.0)
        self.assertEqual(r["agree_by_peer"]["A"]["agree_s"], 11.0)
        self.assertEqual(r["agree_by_peer"]["C"]["agree_s"], 17.0)
        self.assertEqual(r["agree_s"], 17.0)          # the maximum: agreement with all of them
        self.assertEqual(r["sync_s"], 12.0)
        self.assertEqual(r["height_gap"], {"A": 8, "C": 8})


class Advance(unittest.TestCase):
    def test_10_headers_advanced(self):
        # B does not mine; at the heal its headersHeight is 7; it reaches 8 at 6000 -> 5.0 s
        s = [row(1000, n("A", "x", headers=9, mining=True), n("B", "y", headers=7, mining=False), event="heal"),
             row(3000, n("A", "x", headers=9), n("B", "y", headers=7)), row(6000, n("A", "x", headers=9), n("B", "y", headers=8))]
        r = run(s, [heal(1000)])["recovery"][0]
        self.assertEqual(r["headers_advanced"]["B"]["headers_advanced_s"], 5.0)
        self.assertNotIn("A", r["headers_advanced"])      # A mines
        # censored: B never rises
        s[2] = row(6000, n("A", "x", headers=9), n("B", "y", headers=7))
        r = run(s, [heal(1000)])["recovery"][0]
        self.assertEqual((r["headers_advanced"]["B"]["headers_advanced_s"], r["headers_advanced"]["B"]["reason"]), (None, "not_advanced"))
        # censored: the height at the event is unknown (B did not answer the event's sample)
        s[0] = row(1000, n("A", "x", headers=9, mining=True), n("B", answered=False, mining=False), event="heal")
        self.assertEqual(run(s, [heal(1000)])["recovery"][0]["headers_advanced"]["B"]["reason"], "event_height_unknown")


class Cpu(unittest.TestCase):
    def test_3_pid_change_across_relaunch(self):
        # pid 10: 100 -> 250 ticks; relaunch; pid 11 (first sample 40 ticks) -> 90. cpu_s = (250 + 90) / 100 = 3.4
        s = [row(1000, n("A", pid=10, ticks=100)), row(2000, n("A", pid=10, ticks=250)),
             row(3000, n("A", answered=False, state="down")), row(4000, n("A", pid=11, ticks=40)), row(5000, n("A", pid=11, ticks=90))]
        tot = costs.node_totals(s, [], ["A"], {}, CLK)["A"]
        self.assertEqual(tot["cpu_s"], 3.4)
        self.assertEqual(tot["pids"], [10, 11])

    def test_6_pid_not_found_is_null(self):
        s = [row(1000, n("A", answered=False, state="down")), row(2000, n("A", answered=False, state="down"))]
        tot = costs.node_totals(s, [], ["A"], {}, CLK)["A"]
        self.assertIsNone(tot["cpu_s"])
        self.assertIsNone(tot["rss_mb_max"])

    def test_11_cpu_window_delta(self):
        # window (1000, end): pid 10 last before = 100, last in = 180 -> 80; pid 11 starts inside: 30 - 0 -> 30.
        # (80 + 30) / 100 = 1.1
        s = [row(500, n("A", pid=10, ticks=100)), row(1500, n("A", pid=10, ticks=180)), row(2500, n("A", pid=11, ticks=30))]
        self.assertEqual(costs.cpu_in_span(s, "A", 1000, None, CLK), 1.1)

    def test_planned_and_unexpected_downtime(self):
        ev = [{"t": 2500, "kind": "crash", "a": None, "b": None, "node": "B", "detail": None}]
        s = [row(1000, n("B", answered=False)),                                  # unexpected
             row(2000, n("B", "x")), row(3000, n("B", answered=False, state="down")), row(4000, n("B", answered=False)),
             row(5000, n("B", "x")), row(6000, n("B", answered=False))]            # after it answered again: unexpected
        tot = costs.node_totals(s, ev, ["B"], {}, CLK)["B"]
        self.assertEqual((tot["unanswered_planned"], tot["unanswered_unexpected"]), (2, 2))


class Latency(unittest.TestCase):
    def test_5_timeouts_counted_apart_no_process_in_neither(self):
        s = [row(1000, n("A", "x"), n("B", "y"), event="heal"),
             row(2000, n("A", "x", pid=1, ms=10.0), n("B", "y", pid=2, ms=30.0)),
             row(3000, n("A", "x", pid=1, ms=20.0), n("B", answered=False, pid=2, timeout=True)),
             row(4000, n("A", "x", pid=1, ms=40.0), n("B", answered=False, state="down", pid=None, timeout=False))]
        r = run(s, [heal(1000)])["recovery"][0]
        b = r["per_node"]["B"]
        self.assertEqual((b["loopback_info_calls"], b["loopback_info_timeouts"], b["loopback_info_ms_max"]), (1, 1, 30.0))
        a = r["per_node"]["A"]
        self.assertEqual((a["loopback_info_ms_p50"], a["loopback_info_ms_max"], a["loopback_info_ms_p95"]), (20.0, 40.0, None))

    def test_nearest_rank(self):
        v = list(range(1, 21))                 # 20 values: p95 = ceil(19) = 19th
        self.assertEqual(costs.nearest_rank(v, 95), 19)
        self.assertEqual(costs.nearest_rank(v, 50), 10)


if __name__ == "__main__":
    unittest.main()
