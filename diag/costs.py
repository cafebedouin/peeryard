#!/usr/bin/env python3
"""costs.py: what recovery cost, from a rig run's samples.jsonl, events.jsonl and effective.json.

  python3 diag/costs.py <run log dir> [--json]

Writes <dir>/costs.json and prints a one-line summary. A report, never a verdict: no PASS rule reads costs.json.

Per recovery event (heal a b; revive n; relaunch n):
  agree_s        seconds from the event to the first regular sample k at which the pair's bestFullHeaderId are equal
                 (and non-null) and still equal at the next regular sample (event-time samples are left out of this
                 series). Its resolution is the sample interval, and under a live miner at 2 s blocks it runs late by a
                 few intervals, since two tips read in one sample are rarely of the same moment. When no such k is in
                 the window: null + censored with one reason, by precedence endpoint_down (a sample in the window went
                 unanswered by either node; after a revive or relaunch, counted from the node's first answer), then
                 next_event (a later event closed the window), then never_agreed. null with status
                 nothing_to_recover when the tips were already equal at the event.
                 After revive/relaunch n: agreement with each node not restarted in the window and running at the
                 event, per node; agree_s is the maximum (agreement with all of them), censored if any is.
  height_gap, tips_equal_at_event, height_at_event   from the event's own sample (a heal), or from the revived node's
                 first answered sample with a non-zero height (a revive or relaunch: it cannot answer at the event,
                 and it answers with height 0 while it reloads its chain). null where a node did not answer.
  first_answer_s, sync_s   (revive/relaunch) the first answered regular sample; sync_s = agree_s - first_answer_s.
  headers_advanced_s   per node that does not mine: until its headersHeight first rises above its value at the event.
                 An upper bound on link recovery (it includes the wait for the next block and the sample phase), so
                 agree_s - headers_advanced_s approximates catch-up. Censored when it never rises in the window
                 (no block mined, or no recovery) or the event height is unknown.
  cpu_s_in_window  per node: per pid, the last cumulative utime+stime in the span minus the last value before it (zero
                 when the pid starts inside it), over CLK_TCK; it can miss up to one sample at each edge.
  loopback_info_ms p50/p95/max over completed /info calls (nearest rank; p95 only with at least 20), with
                 loopback_info_timeouts: timed-out calls while the node's process existed. Samples with no process
                 count in neither.
  The span for the CPU and latency figures runs from the event to agreement, or to the window's end when censored.

Windows: a link event's (partition, heal, link_netem) runs to the next event on the same link, or a crash, revive or
relaunch of either node; a node event's (crash, revive, relaunch) to the next such event on that node or a link
event touching it; otherwise to the end of the run. mark and launch events never close a window.

Per node: cpu_s (sum over its pids of each pid's last observed cumulative ticks, over CLK_TCK; ticks after a pid's
last sample are lost), rss_mb_max (the maximum over samples; a peak between samples is missed), and unanswered
regular samples, counted as planned (from a crash or relaunch, or before a deferred node's first launch, until the
node's first answer after it comes back) and unexpected. A pid never found gives null, never 0.
Standard library only.
"""
import json
import os
import sys
from typing import Dict, List, Optional, Tuple

LINK_KINDS = ("partition", "heal", "link_netem")
NODE_KINDS = ("crash", "revive", "relaunch")
RECOVERY_KINDS = ("heal", "revive", "relaunch")


def load_jsonl(path: str) -> List[dict]:
    rows = []
    if not os.path.exists(path):
        return rows
    with open(path) as fh:
        for line in fh:
            line = line.strip()
            if line:
                rows.append(json.loads(line))
    return rows


def node_of(row: dict, name: str) -> Optional[dict]:
    for n in row.get("nodes", []):
        if n.get("name") == name:
            return n
    return None


def answered(s: Optional[dict]) -> bool:
    return bool(s and s.get("answered"))


def tip(row: dict, name: str) -> Optional[str]:
    s = node_of(row, name)
    return s.get("bestFullHeaderId") if answered(s) else None


def nearest_rank(values: List[float], p: float) -> Optional[float]:
    if not values:
        return None
    v = sorted(values)
    k = max(1, -(-len(v) * p // 100))  # ceil(n * p / 100), at least 1
    return v[int(k) - 1]


def involves(ev: dict, name: str) -> bool:
    return name in (ev.get("a"), ev.get("b"), ev.get("node"))


def window_end(events: List[dict], i: int) -> Tuple[Optional[int], Optional[dict]]:
    """(end t, closing event) of event i's window; (None, None) when it runs to the end of the run."""
    ev = events[i]
    for later in events[i + 1:]:
        k = later.get("kind")
        if k in ("mark", "launch"):
            continue
        if ev["kind"] in LINK_KINDS:
            same_link = k in LINK_KINDS and {later.get("a"), later.get("b")} == {ev.get("a"), ev.get("b")}
            node_hit = k in NODE_KINDS and later.get("node") in (ev.get("a"), ev.get("b"))
            if same_link or node_hit:
                return later["t"], later
        else:
            n = ev.get("node")
            if (k in NODE_KINDS and later.get("node") == n) or (k in LINK_KINDS and involves(later, n)):
                return later["t"], later
    return None, None


def event_sample(samples: List[dict], ev: dict) -> Optional[dict]:
    """The out-of-cycle sample taken right after the event (the first event row of its kind at or after it)."""
    for row in samples:
        if row.get("event") == ev["kind"] and row["t"] >= ev["t"]:
            return row
    return None


def in_span(row: dict, t0: int, t1: Optional[int]) -> bool:
    return row["t"] > t0 and (t1 is None or row["t"] < t1)


def agreement(regular: List[dict], a: str, b: str, t0: int, t1: Optional[int], down_from: int,
              closed_by_event: bool) -> dict:
    """agree_s for the pair over the regular samples in (t0, t1), by the k / k+1 rule, or its censoring."""
    rows = [r for r in regular if in_span(r, t0, t1)]
    for k in range(len(rows) - 1):
        ta, tb = tip(rows[k], a), tip(rows[k], b)
        if ta is not None and ta == tb and tip(rows[k + 1], a) == ta and tip(rows[k + 1], b) == ta:
            return {"agree_s": round((rows[k]["t"] - t0) / 1000, 3), "censored": False, "agreed_t": rows[k]["t"]}
    if any(r["t"] >= down_from and not (answered(node_of(r, a)) and answered(node_of(r, b))) for r in rows):
        reason = "endpoint_down"
    elif closed_by_event:
        reason = "next_event"
    else:
        reason = "never_agreed"
    return {"agree_s": None, "censored": True, "reason": reason, "agreed_t": None}


def headers_advanced(regular: List[dict], name: str, h0: Optional[int], t0: int, t1: Optional[int]) -> dict:
    if h0 is None:
        return {"headers_advanced_s": None, "censored": True, "reason": "event_height_unknown"}
    for r in regular:
        if not in_span(r, t0, t1):
            continue
        s = node_of(r, name)
        if answered(s) and (s.get("headersHeight") or 0) > h0:
            return {"headers_advanced_s": round((r["t"] - t0) / 1000, 3), "censored": False}
    return {"headers_advanced_s": None, "censored": True, "reason": "not_advanced"}


def cpu_in_span(samples: List[dict], name: str, t0: int, t1: Optional[int], clk_tck: int) -> Optional[float]:
    before: Dict[int, int] = {}
    last_in: Dict[int, int] = {}
    for r in samples:
        s = node_of(r, name)
        if not s or s.get("pid") is None or s.get("cpu_ticks") is None:
            continue
        if r["t"] <= t0:
            before[s["pid"]] = s["cpu_ticks"]
        elif t1 is None or r["t"] < t1:
            last_in[s["pid"]] = s["cpu_ticks"]
    if not last_in:
        return None
    return round(sum(v - before.get(pid, 0) for pid, v in last_in.items()) / clk_tck, 2)


def latency_in_span(samples: List[dict], name: str, t0: int, t1: Optional[int]) -> dict:
    ms, timeouts = [], 0
    for r in samples:
        if not in_span(r, t0, t1):
            continue
        s = node_of(r, name)
        if not s or s.get("pid") is None:
            continue  # no process: neither a completed call nor a timeout
        if s.get("timeout"):
            timeouts += 1
        elif s.get("loopback_info_ms") is not None:
            ms.append(s["loopback_info_ms"])
    return {"loopback_info_ms_p50": nearest_rank(ms, 50),
            "loopback_info_ms_p95": nearest_rank(ms, 95) if len(ms) >= 20 else None,
            "loopback_info_ms_max": max(ms) if ms else None, "loopback_info_calls": len(ms),
            "loopback_info_timeouts": timeouts}


def mining_of(row: Optional[dict], name: str, default: bool) -> bool:
    s = node_of(row, name) if row else None
    if s is not None and s.get("mining") is not None:
        return bool(s["mining"])
    return default


def first_answer(regular: List[dict], name: str, t0: int, t1: Optional[int], nonzero: bool = False) -> Optional[dict]:
    for r in regular:
        if in_span(r, t0, t1):
            s = node_of(r, name)
            if answered(s) and (not nonzero or (s.get("fullHeight") or 0) > 0):
                return r
    return None


def recovery(samples: List[dict], events: List[dict], i: int, cfg_mining: Dict[str, bool], clk_tck: int) -> dict:
    ev = events[i]
    regular = [r for r in samples if not r.get("event")]
    t0 = ev["t"]
    t1, closer = window_end(events, i)
    out = {"kind": ev["kind"], "t": t0, "detail": ev.get("detail"),
           "window_end_t": t1, "closed_by": closer["kind"] if closer else None}
    if ev["kind"] == "heal":
        a, b = ev["a"], ev["b"]
        out.update(a=a, b=b)
        es = event_sample(samples, ev)
        sa, sb = (node_of(es, a), node_of(es, b)) if es else (None, None)
        ha = sa.get("fullHeight") if answered(sa) else None
        hb = sb.get("fullHeight") if answered(sb) else None
        out["height_at_event"] = {a: ha, b: hb}
        out["height_gap"] = ha - hb if ha is not None and hb is not None else None
        eq = (sa.get("bestFullHeaderId") == sb.get("bestFullHeaderId")) if answered(sa) and answered(sb) else None
        out["tips_equal_at_event"] = eq
        if eq:
            out.update(agree_s=None, status="nothing_to_recover", censored=False)
            end_t = t1
        else:
            ag = agreement(regular, a, b, t0, t1, t0, closer is not None)
            out.update(agree_s=ag["agree_s"], censored=ag["censored"])
            if ag["censored"]:
                out["reason"] = ag["reason"]
            end_t = ag["agreed_t"] + 1 if ag["agreed_t"] is not None else t1
        nodes = [a, b]
        ref = {a: (sa.get("headersHeight") if answered(sa) else None), b: (sb.get("headersHeight") if answered(sb) else None)}
        ref_row = es
    else:
        n = ev["node"]
        out["node"] = n
        es = event_sample(samples, ev)
        all_names = [s["name"] for s in (samples[0]["nodes"] if samples else [])]
        restarted = {e.get("node") for e in events[i + 1:] if e.get("kind") in NODE_KINDS + ("launch",)
                     and e["t"] > t0 and (t1 is None or e["t"] < t1)}
        peers = [p for p in all_names if p != n and p not in restarted
                 and (es is None or (node_of(es, p) or {}).get("state") == "running")]
        out["peers"] = peers
        fa = first_answer(regular, n, t0, t1)
        out["first_answer_s"] = round((fa["t"] - t0) / 1000, 3) if fa else None
        ref_row = first_answer(regular, n, t0, t1, nonzero=True)
        down_from = fa["t"] if fa else t0
        per, heights, gaps, eqs = {}, {}, {}, {}
        sn = node_of(ref_row, n) if ref_row else None
        heights[n] = sn.get("fullHeight") if answered(sn) else None
        for p in peers:
            sp = node_of(ref_row, p) if ref_row else None
            heights[p] = sp.get("fullHeight") if answered(sp) else None
            gaps[p] = heights[p] - heights[n] if heights[p] is not None and heights[n] is not None else None
            eqs[p] = (sp.get("bestFullHeaderId") == sn.get("bestFullHeaderId")) if answered(sp) and answered(sn) else None
            per[p] = agreement(regular, p, n, t0, t1, down_from, closer is not None)
        out["height_at_event"] = heights
        out["height_gap"] = gaps          # per peer: the peer's full height minus the revived node's
        out["tips_equal_at_event"] = eqs
        out["agree_by_peer"] = {p: {k: v for k, v in r.items() if k != "agreed_t"} for p, r in per.items()}
        if peers and all(eqs.get(p) for p in peers):
            out.update(agree_s=None, status="nothing_to_recover", censored=False)
            end_t = t1
        elif not peers:
            out.update(agree_s=None, censored=True, reason="no_peer")
            end_t = t1
        else:
            cens = [r for r in per.values() if r["censored"]]
            if cens:
                order = ["endpoint_down", "next_event", "never_agreed"]
                out.update(agree_s=None, censored=True, reason=min((r["reason"] for r in cens), key=order.index))
                end_t = t1
            else:
                out.update(agree_s=max(r["agree_s"] for r in per.values()), censored=False)
                end_t = max(r["agreed_t"] for r in per.values()) + 1
        if out.get("agree_s") is not None and out["first_answer_s"] is not None:
            out["sync_s"] = round(out["agree_s"] - out["first_answer_s"], 3)
        else:
            out["sync_s"] = None
        nodes = [n] + peers
        ref = {x: ((node_of(ref_row, x) or {}).get("headersHeight") if ref_row and answered(node_of(ref_row, x)) else None)
               for x in nodes}
    adv = {}
    for x in nodes:
        if not mining_of(ref_row, x, cfg_mining.get(x, False)):
            adv[x] = headers_advanced(regular, x, ref.get(x), ref_row["t"] if ref_row else t0, t1)
    out["headers_advanced"] = adv
    out["span_end_t"] = end_t
    out["per_node"] = {x: dict(cpu_s_in_window=cpu_in_span(samples, x, t0, end_t, clk_tck),
                               **latency_in_span(samples, x, t0, end_t)) for x in nodes}
    return out


def node_totals(samples: List[dict], events: List[dict], names: List[str], deferred: Dict[str, bool],
                clk_tck: int) -> Dict[str, dict]:
    regular = [r for r in samples if not r.get("event")]
    out = {}
    for n in names:
        last: Dict[int, int] = {}
        rss = []
        for r in samples:
            s = node_of(r, n)
            if not s:
                continue
            if s.get("pid") is not None and s.get("cpu_ticks") is not None:
                last[s["pid"]] = s["cpu_ticks"]
            if s.get("rss_mb") is not None:
                rss.append(s["rss_mb"])
        # planned downtime: from a crash or relaunch (or, for a deferred node, the start) to the first answer after it
        downs = sorted(e["t"] for e in events if e.get("node") == n and e.get("kind") in ("crash", "relaunch"))
        planned = unexpected = 0
        in_planned = bool(deferred.get(n))
        di = 0
        for r in regular:
            while di < len(downs) and downs[di] <= r["t"]:
                in_planned = True
                di += 1
            s = node_of(r, n)
            if answered(s):
                in_planned = False
            elif in_planned:
                planned += 1
            else:
                unexpected += 1
        out[n] = {"cpu_s": round(sum(last.values()) / clk_tck, 2) if last else None,
                  "pids": sorted(last), "rss_mb_max": max(rss) if rss else None,
                  "unanswered_planned": planned, "unanswered_unexpected": unexpected}
    return out


def compute(samples: List[dict], events: List[dict], effective: dict, clk_tck: int) -> dict:
    cfg_nodes = effective.get("nodes", [])
    names = [n["name"] for n in cfg_nodes] or ([s["name"] for s in samples[0]["nodes"]] if samples else [])
    cfg_mining = {n["name"]: bool(n.get("mining")) for n in cfg_nodes}
    deferred = {n["name"]: bool(n.get("defer")) for n in cfg_nodes}
    events = sorted(events, key=lambda e: e["t"])
    rec = [recovery(samples, events, i, cfg_mining, clk_tck) for i, e in enumerate(events) if e["kind"] in RECOVERY_KINDS]
    return {"costs_schema_version": 1, "clk_tck": clk_tck,
            "note": "agree_s: strict bestFullHeaderId equality at two consecutive regular samples; resolution is the "
                    "sample interval, and under a live miner it runs late by a few intervals",
            "recovery": rec, "nodes": node_totals(samples, events, names, deferred, clk_tck)}


def fmt(x) -> str:
    return "-" if x is None else f"{x:g}"


def summary(c: dict) -> str:
    if not c["recovery"]:
        return "no recovery events"
    parts = []
    for r in c["recovery"]:
        who = f"{r['a']}-{r['b']}" if r["kind"] == "heal" else r["node"]
        tag = f" ({r['detail']})" if r.get("detail") else ""
        if r.get("status") == "nothing_to_recover":
            v = "nothing to recover"
        elif r.get("censored"):
            v = f"censored {r.get('reason')}"
        else:
            v = f"agree_s={fmt(r['agree_s'])}"
            if r["kind"] != "heal":
                v += f" first_answer_s={fmt(r['first_answer_s'])}"
        parts.append(f"{r['kind']} {who}{tag}: {v}")
    return "; ".join(parts)


def main(argv: List[str]) -> int:
    args = [a for a in argv if not a.startswith("--")]
    if len(args) != 1:
        print(__doc__.split("\n\n")[1], file=sys.stderr)
        return 2
    d = args[0]
    eff_path = os.path.join(d, "effective.json")
    effective = json.load(open(eff_path)) if os.path.exists(eff_path) else {}
    c = compute(load_jsonl(os.path.join(d, "samples.jsonl")), load_jsonl(os.path.join(d, "events.jsonl")),
                effective, os.sysconf("SC_CLK_TCK"))
    with open(os.path.join(d, "costs.json"), "w") as fh:
        json.dump(c, fh, indent=1)
    print(json.dumps(c) if "--json" in argv else summary(c))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
