#!/usr/bin/env python3
"""summarize.py: summarise run results (results-V*.json) against the corpus. Stdlib only.

usage: summarize.py CORPUS.json RESULTS_V0.json RESULTS_V1.json RESULTS_V2.json

Prints: controls, per-version counts per step per contract, the per-tx table (markdown), and every
distinct failure string. Tx kind comes from context var 0 (the op byte) of the Lithos inputs, with the
op names from Lithos-Client 14ad1fe LDHelpers.scala:61-81.
"""
import collections
import json
import sys

POOL_OPS = {0: "swap", 1: "deposit", 2: "redeem", 3: "flush", 4: "resize"}
VAULT_OPS = {0: "claim", 1: "flush"}
PROV_OPS = {0: "claim", 1: "redeem", 2: "refresh", 3: "resize"}


def op_of(ext):
    v = (ext or {}).get("0")
    if v and v.startswith("02") and len(v) == 4:  # SByte
        return int(v[2:], 16)
    return None


def kind(entry, contracts):
    tx = entry["tx"]
    parts = []
    for inp, c in zip(tx["inputs"], contracts):
        op = op_of(inp.get("spendingProof", {}).get("extension"))
        if c == "LD_LiquidityPool":
            parts.append("pool:" + POOL_OPS.get(op, str(op)))
        elif c == "LD_FeeVault":
            parts.append("vault:" + VAULT_OPS.get(op, str(op)))
        elif c == "LD_Provision(guard)":
            parts.append("prov:" + PROV_OPS.get(op, str(op)))
    if "pool:resize" in parts:
        k = "RESIZE"
    elif "vault:claim" in parts:
        k = "CLAIM"
    elif parts:
        k = parts[0].split(":")[1].upper()
    else:
        k = "control"
    return k, parts


def main():
    corpus = json.load(open(sys.argv[1]))
    runs = [json.load(open(p)) for p in sys.argv[2:5]]
    by = [{r["txId"]: r for r in run["results"]} for run in runs]
    labels = [run["label"] for run in runs]

    print("== versions")
    for run in runs:
        print(f"{run['label']}: {run['lib_name']}@{run['lib_version']} wasm_sha256={run['wasm_sha256']} "
              f"node={run['node']} corpus_sha256={run['corpus_sha256']} shims={run['shims']} "
              f"crashed={sum(1 for r in run['results'] if r.get('child_crashed'))} "
              f"range_errors={sum(1 for r in run['results'] for x in r.get('inputs', []) for s in ('a','b') if x[s].get('range_error')) + sum(1 for r in run['results'] if r.get('c',{}).get('range_error') or r.get('d',{}).get('range_error') or r.get('range_error'))}")

    pool_sha = corpus["resolution"]["pool_tree_sha256"]
    print("\n== controls")
    for run in runs:
        L = run["label"]
        pool_a = [x for r in run["results"] for x in r["inputs"] if x["tree_sha256"] == pool_sha]
        ncb = [x for x in pool_a if not x["a"]["pass"] and "NonConsumedBytes" in (x["a"].get("err") or "")]
        p2pk = [x for r in run["results"] for x in r["inputs"] if x["contract"] == "P2PK"]
        p2pk_ok = [x for x in p2pk if x["b"].get("value") is True]
        ctrl = [r for r in run["results"] if "control_sigusd_bank" in r["sets"]][0]
        ctrl_ok = all(x["a"]["pass"] for x in ctrl["inputs"]) and all(x["b"]["pass"] for x in ctrl["inputs"]) and ctrl["c"]["pass"]
        print(f"{L}: pool-tree(1bbe,{corpus['resolution']['pool_tree_len']}B) step a fails with NonConsumedBytes: "
              f"{len(ncb)}/{len(pool_a)} | P2PK inputs verify true: {len(p2pk_ok)}/{len(p2pk)} | "
              f"SigUSD control a-c pass: {ctrl_ok} (tx {ctrl['txId']})")

    print("\n== per version, per contract: step a / step b pass counts (inputs)")
    contracts = sorted({x["contract"] for run in runs for r in run["results"] for x in r["inputs"]})
    for run in runs:
        for c in contracts:
            xs = [x for r in run["results"] for x in r["inputs"] if x["contract"] == c]
            print(f"{run['label']} {c:22s} a {sum(x['a']['pass'] for x in xs):3d}/{len(xs):3d}  "
                  f"b {sum(x['b']['pass'] for x in xs):3d}/{len(xs):3d}")
    print("\n== per version: step c / step d pass counts (txs)")
    kinds = {}
    for e in corpus["txs"]:
        cs = [x["contract"] for x in by[0][e["txId"]]["inputs"]]
        kinds[e["txId"]] = kind(e, cs)
    for run in runs:
        rs = run["results"]
        dd = [r for r in rs if r["d"]["applicable"]]
        d354 = [r for r in dd if r["shape354"]]
        print(f"{run['label']}: c {sum(r['c']['pass'] for r in rs)}/{len(rs)}  "
              f"d(all P2PK-bearing) {sum(r['d']['pass'] for r in dd)}/{len(dd)}  "
              f"d(#354 shape: pool+P2PK) {sum(r['d']['pass'] for r in d354)}/{len(d354)}")
        for k in sorted({v[0] for v in kinds.values()}):
            ks = [r for r in rs if kinds[r["txId"]][0] == k]
            full = [r for r in ks if all(x["a"]["pass"] and x["b"]["pass"] for x in r["inputs"]) and r["c"]["pass"]
                    and (not r["d"]["applicable"] or r["d"]["pass"])]
            print(f"   kind {k:8s} txs {len(ks):3d}  all-steps-pass {len(full):3d}")

    print("\n== tx kinds in corpus")
    print(collections.Counter(v[0] for v in kinds.values()))

    def cell(r):
        a = sum(x["a"]["pass"] for x in r["inputs"]); b = sum(x["b"]["pass"] for x in r["inputs"]); n = len(r["inputs"])
        d = ("P" if r["d"]["pass"] else "F") if r["d"]["applicable"] else "-"
        return f"{a}/{n} {b}/{n} {'P' if r['c']['pass'] else 'F'} {d}"

    print("\n== per-tx table (a = inputs parsed / n, b = inputs verified / n, c = reduce, d = sign-to-key-missing)")
    print("| # | tx id | height | sets | kind | Lithos inputs (op) | " + " | ".join(f"{L} a b c d" for L in labels) + " |")
    print("|---|---|---|---|---|---|" + "---|" * len(labels))
    for i, e in enumerate(corpus["txs"]):
        t = e["txId"]
        k, parts = kinds[t]
        print(f"| {i+1} | `{t}` | {e['inclusionHeight']} | {','.join(e['sets'])} | {k} | {' '.join(parts) or '-'} | "
              + " | ".join(cell(b[t]) for b in by) + " |")

    print("\n== distinct failure strings (version, step, contract, count, error)")
    for run in runs:
        cnt = collections.Counter()
        for r in run["results"]:
            for x in r["inputs"]:
                for s in ("a", "b"):
                    if not x[s]["pass"]:
                        cnt[(s, x["contract"], x[s].get("err") or f"value={x[s].get('value')}")] += 1
            if not r["c"]["pass"]:
                cnt[("c", kinds[r["txId"]][0], r["c"].get("err"))] += 1
            if r["d"]["applicable"] and not r["d"]["pass"]:
                cnt[("d", kinds[r["txId"]][0], r["d"].get("err"))] += 1
        for (s, c, err), n in sorted(cnt.items()):
            print(f"{run['label']} step {s} {c} x{n}: {json.dumps(err)}")


if __name__ == "__main__":
    main()
