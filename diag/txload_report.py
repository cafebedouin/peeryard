#!/usr/bin/env python3
"""txload_report.py <run dir> [--json]: one record per payment of rig/lib/txload.sh, and a summary line.

Reads, from <run dir> or <run dir>/out: txload.jsonl (the payments as sent), txwatch.jsonl (input blocks and best full
blocks as the observer saw them), txload_pools.json (each node's pool when the load window ended) and
txload_chain.jsonl (the blocks of one node's final chain, with their transaction ids). Writes txrecords.jsonl beside
them, one object per accepted payment:
  id, kind (fund | pay), node (the payer), to, t_submit_ms, chain_pos, chain_len,
  dependent      an input is an output of an earlier payment of this run (it spent unconfirmed change)
  input          {t_ms, node, id}: the first observation of the payment in an input block (any node), or null
  input_by_node  {node: t_ms} first observation per node
  ordering       {h, id, ts, seen_ms, seen_node}: the block of the final chain that holds it (ts: the header's own
                 timestamp; seen_ms: the first poll at which a node had that block as its best full block, or null)
  status         confirmed | pending (in a pool when the window ended) | lost (neither)
and prints one line:
  MATRIX-TXLOAD attempts= accepted= rejected= skipped_ticks= fund= dependent= in_input= confirmed= pending= lost=
    dependent_lost= input_ms_p50= input_ms_p90= ordering_ms_p50= ordering_ms_p90= ordering_ts_ms_p50=
(input_ms: submit -> first input-block observation; ordering_ms: submit -> first poll showing the holding block as
best; ordering_ts_ms: submit -> the holding header's timestamp; percentiles over the payments that have one.)
--json prints the counts as one JSON object instead. Standard library only."""
import json
import math
import os
import sys


def _path(run, name):
    for p in (os.path.join(run, name), os.path.join(run, "out", name)):
        if os.path.exists(p):
            return p
    return None


def _jsonl(run, name):
    p = _path(run, name)
    if p is None:
        return []
    out = []
    with open(p) as fh:
        for line in fh:
            line = line.strip()
            if line:
                try:
                    out.append(json.loads(line))
                except ValueError:
                    pass
    return out


def pct(xs, q):
    if not xs:
        return None
    xs = sorted(xs)   # nearest rank
    return xs[max(0, math.ceil(q * len(xs)) - 1)]


def build(run):
    sends = _jsonl(run, "txload.jsonl")
    watch = _jsonl(run, "txwatch.jsonl")
    chain = _jsonl(run, "txload_chain.jsonl")
    pp = _path(run, "txload_pools.json")
    pools = json.load(open(pp)) if pp else {}
    in_input = {}   # tx id -> {node: (t, input id)}
    full_seen = {}  # block id -> (t, node)
    for w in watch:
        if w.get("ev") == "input":
            for t in w.get("txs") or []:
                by = in_input.setdefault(t, {})
                if w["node"] not in by or w["t_ms"] < by[w["node"]][0]:
                    by[w["node"]] = (w["t_ms"], w["id"])
        elif w.get("ev") == "full":
            if w["id"] not in full_seen or w["t_ms"] < full_seen[w["id"]][0]:
                full_seen[w["id"]] = (w["t_ms"], w["node"])
    in_block = {}
    for b in chain:
        for t in b.get("txs") or []:
            in_block.setdefault(t, b)
    pooled = {}
    for n, ids in pools.items():
        for t in ids:
            pooled.setdefault(t, []).append(n)
    made = set()
    recs = []
    c = dict(attempts=0, accepted=0, rejected=0, skipped_ticks=0, fund=0, dependent=0, in_input=0, confirmed=0,
             pending=0, lost=0, dependent_lost=0)
    lat_in, lat_ord, lat_ts = [], [], []
    for s in sends:
        if s.get("kind") == "skip":
            c["skipped_ticks"] += 1
            continue
        c["attempts"] += 1
        if not s.get("id"):
            c["rejected"] += 1
            continue
        c["accepted"] += 1
        c["fund"] += s["kind"] == "fund"
        tid = s["id"]
        dep = any(i in made for i in (s.get("inputs") or []))
        made.update(s.get("outputs") or [])
        by = in_input.get(tid, {})
        first = min(by.items(), key=lambda kv: kv[1][0]) if by else None
        b = in_block.get(tid)
        ordering = None
        if b:
            seen = full_seen.get(b["id"])
            ordering = dict(h=b["h"], id=b["id"], ts=b.get("ts"), seen_ms=seen[0] if seen else None,
                            seen_node=seen[1] if seen else None)
        status = "confirmed" if b else ("pending" if tid in pooled else "lost")
        r = dict(id=tid, kind=s["kind"], node=s["node"], to=s.get("to"), t_submit_ms=s["t_ms"],
                 chain_pos=s.get("chain_pos"), chain_len=s.get("chain_len"), dependent=dep,
                 input=dict(t_ms=first[1][0], node=first[0], id=first[1][1]) if first else None,
                 input_by_node={n: v[0] for n, v in by.items()}, ordering=ordering, status=status,
                 pending_in=pooled.get(tid, []))
        recs.append(r)
        c["dependent"] += dep
        c["in_input"] += first is not None
        c[status] += 1
        c["dependent_lost"] += dep and status == "lost"
        if first:
            lat_in.append(first[1][0] - s["t_ms"])
        if ordering and ordering["seen_ms"] is not None:
            lat_ord.append(ordering["seen_ms"] - s["t_ms"])
        if ordering and ordering["ts"] is not None:
            lat_ts.append(ordering["ts"] - s["t_ms"])
    c.update(input_ms_p50=pct(lat_in, 0.5), input_ms_p90=pct(lat_in, 0.9), ordering_ms_p50=pct(lat_ord, 0.5),
             ordering_ms_p90=pct(lat_ord, 0.9), ordering_ts_ms_p50=pct(lat_ts, 0.5))
    return recs, c


def main(argv):
    if not argv or argv[0].startswith("-"):
        print(__doc__)
        return 2
    run = argv[0]
    recs, c = build(run)
    base = os.path.dirname(_path(run, "txload.jsonl") or os.path.join(run, "txload.jsonl"))
    with open(os.path.join(base, "txrecords.jsonl"), "w") as fh:
        for r in recs:
            fh.write(json.dumps(r, sort_keys=True) + "\n")
    if "--json" in argv:
        print(json.dumps(c))
    else:
        print("MATRIX-TXLOAD " + " ".join(f"{k}={'-' if v is None else v}" for k, v in c.items()))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
