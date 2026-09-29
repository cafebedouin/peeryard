"""matrix_tx.py <run dir> [...]: how transactions travel inside Matrix input blocks on a line A - B - C (A mines and
pays; rig/examples/matrix-txload.sh). Reads each run's payments.jsonl ({t_ms, id}, written by the hook) and
messages.jsonl (diag/wire.py; the rig captures A-B at A and B-C at B, both directions).

A transaction is known on the wire by its weak id (6 bytes: the first 3 of the transaction id, then 3 of its witness
id), so a payment is matched to weak ids by the first 6 hex characters of its id. For each hop S -> R (A -> B, B -> C):
  body     the first Modifiers frame (33, transactions, type 2) S -> R carrying the payment: ordinary tx relay
  listed   the first frame S -> R that lists the payment's weak id for an input block: an InputBlock (100) that carries
           its weak ids, or an InputBlockTxIds (102, sent when R asked with a RequestModifier of type -122)
  path     asked: R named the weak id in an InputBlockTxsRequest (105) for that input block; mempool: the body had
           crossed before the listing and R asked for nothing; other: neither (listed, body later, never asked)
  lat_ms   t(listed) - t(sent), and for asked, t(InputBlockTxs 104 answer) - t(sent)
Exchanges per hop (R asks, S answers, on the same link): 102 asked (RequestModifier -122) / answered; 105 sent / answered
in full (a later 104 for the same input block with as many transactions) / answered short / unanswered; 105 repeated for
one input block; 104 with no 105 before it on that hop (unpaired).
A run whose capture lost bytes in either direction of A-B or B-C (a gap or desync record) is reported and left out of
its arm's pool. One block per run, then one pooled block per arm (a run dir's basename up to its last '-').
Standard library only."""
import json
import os
import statistics
import sys
from collections import defaultdict

HOPS = (("A", "B", "A-B"), ("B", "C", "B-C"))
TX_TYPE, TXIDS_TYPE = 2, -122


def _load(run, name):
    for p in (os.path.join(run, name), os.path.join(run, "out", name)):
        if os.path.exists(p):
            with open(p) as fh:
                return [json.loads(l) for l in fh if l.strip()]
    return None


def hop_view(msgs, s, r, link):
    """frames on one link, split by direction: fwd = S -> R, back = R -> S, in time order"""
    fr = sorted((m for m in msgs if m.get("kind") == "frame" and m.get("link") == link), key=lambda m: m["t_ms"])
    return [m for m in fr if m.get("from") == s], [m for m in fr if m.get("from") == r]


def exchanges(fwd, back):
    """request/answer pairing on one hop: R asks (back), S answers (fwd)"""
    out = {"ids_asked": 0, "ids_answered": 0, "req": 0, "full": 0, "short": 0, "unanswered": 0, "repeated": 0,
           "unpaired_104": 0, "short_missing": 0, "answer_ms": []}
    asked_ids = [m for m in back if m["code"] == 22 and m.get("type_id") == TXIDS_TYPE]
    out["ids_asked"] = sum(len(m.get("modifier_ids", [])) for m in asked_ids)
    ans_ids = {m["input_block_id"] for m in fwd if m["code"] == 102}
    out["ids_answered"] = sum(1 for m in asked_ids for i in m.get("modifier_ids", []) if i in ans_ids)
    reqs = [m for m in back if m["code"] == 105]
    answers = [m for m in fwd if m["code"] == 104]
    per_ib = defaultdict(int)
    used = set()
    for q in reqs:
        per_ib[q["input_block_id"]] += 1
        a = next((i for i, x in enumerate(answers) if i not in used and x["input_block_id"] == q["input_block_id"]
                  and x["t_ms"] >= q["t_ms"]), None)
        out["req"] += 1
        if a is None:
            out["unanswered"] += 1
            continue
        used.add(a)
        out["answer_ms"].append(answers[a]["t_ms"] - q["t_ms"])
        if answers[a]["count"] >= q["count"]:
            out["full"] += 1
        else:
            out["short"] += 1
            out["short_missing"] += q["count"] - answers[a]["count"]
    out["repeated"] = sum(1 for n in per_ib.values() if n > 1)
    out["unpaired_104"] = len(answers) - len(used)
    return out


def per_payment(pays, fwd, back):
    """per payment on one hop: body time, listing time and input block, path, latencies"""
    body, listed, reqs, answers = {}, {}, defaultdict(list), defaultdict(list)
    for m in fwd:
        if m["code"] == 33 and m.get("type_id") == TX_TYPE:
            for i in m.get("modifier_ids", []):
                body.setdefault(i, m["t_ms"])
        elif m["code"] in (100, 102) and m.get("weak_ids"):
            for w in m["weak_ids"]:
                listed.setdefault(w[:6], (m["t_ms"], m["input_block_id"], m["code"]))
        elif m["code"] == 104:
            answers[m["input_block_id"]].append(m["t_ms"])
    for m in back:
        if m["code"] == 105:
            for w in m.get("weak_ids", []):
                reqs[(m["input_block_id"], w[:6])].append(m["t_ms"])
    rows = []
    for p in pays:
        pre, t0 = p["id"][:6], p["t_ms"]
        row = {"id": p["id"], "body_ms": body[p["id"]] - t0 if p["id"] in body else None,
               "listed_ms": None, "via": None, "path": "unlisted", "answer_ms": None}
        if pre in listed:
            tl, ib, code = listed[pre]
            row["listed_ms"], row["via"] = tl - t0, code
            q = reqs.get((ib, pre))
            if q:
                row["path"] = "asked"
                a = [t for t in answers.get(ib, []) if t >= q[0]]
                row["answer_ms"] = (a[0] - t0) if a else None
            elif p["id"] in body and body[p["id"]] <= tl:
                row["path"] = "mempool"
            else:
                row["path"] = "other"
        rows.append(row)
    return rows


def per_run(run):
    msgs, pays = _load(run, "messages.jsonl") or [], _load(run, "payments.jsonl") or []
    loss = sum(1 for m in msgs if m.get("kind") in ("gap", "desync") and m.get("link") in ("A-B", "B-C"))
    out = {"payments": len(pays), "capture_loss": loss, "hops": {}}
    for s, r, link in HOPS:
        fwd, back = hop_view(msgs, s, r, link)
        ib = [m for m in fwd if m["code"] == 100]
        out["hops"][f"{s}->{r}"] = {
            "input_blocks": len(ib), "ib_none": sum(1 for m in ib if m.get("weak_tx_ids") is None),
            "ib_with_txs": sum(1 for m in ib if m.get("weak_tx_ids")),
            "exchanges": exchanges(fwd, back), "rows": per_payment(pays, fwd, back)}
    return out


def q(v):
    v = [x for x in v if x is not None]
    if not v:
        return "n/a"
    s = sorted(v)
    return f"median {statistics.median(s):.0f} p10 {s[len(s) // 10]} p90 {s[min(len(s) - 1, 9 * len(s) // 10)]} (n {len(s)})"


def hop_lines(h, rows, ex):
    paths = defaultdict(int)
    for x in rows:
        paths[x["path"]] += 1
    lines = [f"payments listed in an input block {sum(1 for x in rows if x['listed_ms'] is not None)}/{len(rows)} "
             f"(mempool {paths['mempool']}, asked {paths['asked']}, other {paths['other']}, unlisted {paths['unlisted']}); "
             f"listed via 100 {sum(1 for x in rows if x['via'] == 100)}, via 102 {sum(1 for x in rows if x['via'] == 102)}",
             f"listed_ms {q([x['listed_ms'] for x in rows])}; asked: answer_ms {q([x['answer_ms'] for x in rows if x['path'] == 'asked'])}",
             f"exchanges: 102 asked {ex['ids_asked']} answered {ex['ids_answered']}; 105 sent {ex['req']}: full {ex['full']}, "
             f"short {ex['short']} (missing {ex['short_missing']}), unanswered {ex['unanswered']}, repeated for one input "
             f"block {ex['repeated']}; 104 unpaired {ex['unpaired_104']}; 105->104 {q(ex['answer_ms'])}"]
    if h is not None:
        lines.insert(0, f"input blocks {h['input_blocks']} (weak ids carried with transactions {h['ib_with_txs']}, "
                        f"not carried {h['ib_none']})")
    return lines


def main(runs):
    pooled = defaultdict(lambda: defaultdict(lambda: {"rows": [], "ex": defaultdict(list)}))
    for run in runs:
        name = os.path.basename(os.path.normpath(run))
        r = per_run(run)
        tag = f" EXCLUDED from the pool: {r['capture_loss']} capture gap(s) or desync(s) on A-B or B-C" if r["capture_loss"] else ""
        print(f"{name}: {r['payments']} payments{tag}")
        for hop, h in r["hops"].items():
            for l in hop_lines(h, h["rows"], h["exchanges"]):
                print(f"  {hop} {l}")
            if not r["capture_loss"]:
                p = pooled[name.rsplit("-", 1)[0]][hop]
                p["rows"] += h["rows"]
                for k, v in h["exchanges"].items():
                    p["ex"][k] += v if isinstance(v, list) else [v]
    print()
    for arm, hops in sorted(pooled.items()):
        for hop, p in hops.items():
            ex = {k: (v if k == "answer_ms" else sum(v)) for k, v in p["ex"].items()}
            for l in hop_lines(None, p["rows"], ex):
                print(f"ARM {arm} {hop} {l}")


if __name__ == "__main__":
    main(sys.argv[1:])
