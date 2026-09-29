"""matrix_prop.py <run dir> [...]: how far and how fast Matrix input blocks travel on a line A - B - C (A mines).
Reads each run's messages.jsonl (diag/wire.py with the Matrix parsers; the rig captures A-B at A and B-C at B):
  sent_AB   input blocks A sent to B (InputBlock 100 frames A->B), first send time per id
  sent_BC   input blocks B sent to C, first send time per id
  reach_C   |sent_AB and sent_BC| / |sent_AB|: the share of A's input blocks that B passed on to C
  hop_ms    t(B->C) - t(A->B) per relayed id (the A-B link's delay plus B's processing)
  dup_AB / dup_BC  frames per id on each link (1 = no duplicates)
  the same for ordering-block announcements (OrderingBlock 106); an ordering block also travels by the ordinary
  header path, so its reach here counts announcements only.
A run whose capture lost bytes on a counted direction (a `gap` or `desync` record from A on A-B or from B on B-C,
including a direction never captured at all) is reported and left out of its arm's pool: an absence there may be a loss
of capture, not of traffic.
One line per run, then one pooled line per arm (a run dir's basename up to its last '-', e.g. base-d150-1 -> base-d150).
Used by .github/workflows/matrix-relay.yml. Standard library only."""
import json
import os
import statistics
import sys
from collections import defaultdict


def load(run):
    p = os.path.join(run, "messages.jsonl")
    if not os.path.exists(p):
        p = os.path.join(run, "out", "messages.jsonl")
    return [json.loads(l) for l in open(p) if l.strip()]


def per_run(msgs):
    out = {}
    for code, key in ((100, "input_block_id"), (106, "ordering_block_id")):
        ab, bc = defaultdict(list), defaultdict(list)
        for m in msgs:
            if m.get("kind") != "frame" or m.get("code") != code or key not in m:
                continue
            if m["link"] == "A-B" and m["from"] == "A":
                ab[m[key]].append(m["t_ms"])
            elif m["link"] == "B-C" and m["from"] == "B":
                bc[m[key]].append(m["t_ms"])
        relayed = [i for i in ab if i in bc]
        hop = [min(bc[i]) - min(ab[i]) for i in relayed]
        out[code] = {"sent_AB": len(ab), "sent_BC": len(bc), "relayed": len(relayed),
                     "reach_C": (len(relayed) / len(ab)) if ab else None, "hop_ms": hop,
                     "dup_AB": [len(v) for v in ab.values()], "dup_BC": [len(v) for v in bc.values()]}
    out["capture_loss"] = sum(1 for m in msgs if m.get("kind") in ("gap", "desync")
                              and (m.get("link"), m.get("from")) in (("A-B", "A"), ("B-C", "B")))
    return out


def q(v):
    if not v:
        return "n/a"
    s = sorted(v)
    return f"median {statistics.median(s):.0f} p10 {s[len(s) // 10]} p90 {s[min(len(s) - 1, 9 * len(s) // 10)]} (n {len(s)})"


def main(runs):
    pooled = defaultdict(lambda: {100: defaultdict(list), 106: defaultdict(list)})
    for run in runs:
        r = per_run(load(run))
        name_ = os.path.basename(os.path.normpath(run))
        arm = name_.rsplit("-", 1)[0]
        if r["capture_loss"]:
            print(f"{name_} EXCLUDED: {r['capture_loss']} capture gap(s) or desync(s) on A->B or B->C")
        for code, name in ((100, "input"), (106, "ordering")):
            x = r[code]
            reach = "n/a" if x["reach_C"] is None else f"{x['reach_C']:.2f}"
            print(f"{os.path.basename(os.path.normpath(run))} {name}: A->B {x['sent_AB']}, B->C {x['sent_BC']}, "
                  f"relayed {x['relayed']}, reach_C {reach}; hop_ms {q(x['hop_ms'])}; "
                  f"dup_AB max {max(x['dup_AB'], default=0)}, dup_BC max {max(x['dup_BC'], default=0)}")
            if r["capture_loss"]:
                continue
            for k in ("hop_ms", "dup_AB", "dup_BC"):
                pooled[arm][code][k] += x[k]
            pooled[arm][code]["reach"].append(x["reach_C"])
    print()
    for arm, d in sorted(pooled.items()):
        for code, name in ((100, "input"), (106, "ordering")):
            rs = [x for x in d[code]["reach"] if x is not None]
            print(f"ARM {arm} {name}: reach_C per run {[round(x, 2) for x in rs]}; hop_ms {q(d[code]['hop_ms'])}; "
                  f"dup_BC mean {statistics.mean(d[code]['dup_BC']) if d[code]['dup_BC'] else 0:.2f}")


if __name__ == "__main__":
    main(sys.argv[1:])
