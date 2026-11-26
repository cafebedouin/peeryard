"""matrix_paychain.py <run dir> [...] [--pool | --json]: what happened to the payments of rig/examples/matrix-paychain.sh.
Reads payments.jsonl ({id, inputs, outputs} per accepted payment, in send order), confirmed.jsonl (the payments found
in a block of B's chain) and a_pool_end.txt (A's pool at the end), from <run dir> or <run dir>/out.
  dependent  an input is an output of an earlier payment of the same run (it spends unconfirmed change)
  lost       neither confirmed nor in A's pool at the end
  pending    not confirmed, still in A's pool
  pool_unknown  not confirmed, and A's pool at the end unknown: a_pool_end.txt is missing, or a_pool_end.err beside it
             says its read failed. Neither lost nor pending; the key is present only when the pool is unknown. An empty
             a_pool_end.txt is an empty pool (all unconfirmed payments lost), as the hook writes it for one.
With --json, a run with pool_unknown > 0 prints nothing and exits 3 (its lost count would be a guess).
One line per run in the hook's format; with --pool, one line per arm (a run dir's basename up to its last '-'),
summing the runs, and the runs with at least one lost payment; with --json, one JSON object per run (the counts, for a
diffrun RESULT_JSON). Standard library only."""
import json
import os
import sys
from collections import defaultdict


def _path(run, name):
    for p in (os.path.join(run, name), os.path.join(run, "out", name)):
        if os.path.exists(p):
            return p
    return None


def _jsonl(run, name):
    p = _path(run, name)
    if p is None:
        return []
    with open(p) as fh:
        return [json.loads(l) for l in fh if l.strip()]


def classify(run):
    pays = _jsonl(run, "payments.jsonl")
    conf = {c["id"] for c in _jsonl(run, "confirmed.jsonl")}
    pp = _path(run, "a_pool_end.txt")
    known = pp is not None and _path(run, "a_pool_end.err") is None
    pool = set(open(pp).read().split()) if known else set()
    made = set()
    r = dict(accepted=len(pays), dependent=0, confirmed=0, dependent_confirmed=0, lost=0, dependent_lost=0,
             pending=0, unknown_inputs=0)
    if not known:
        r["pool_unknown"] = 0
    for p in pays:
        if p.get("inputs") is None:
            r["unknown_inputs"] += 1
        d = any(i in made for i in (p.get("inputs") or []))
        made.update(p.get("outputs") or [])
        c, inpool = p["id"] in conf, p["id"] in pool
        r["dependent"] += d
        r["confirmed"] += c
        r["dependent_confirmed"] += d and c
        if not known:
            r["pool_unknown"] += not c
            continue
        r["pending"] += (not c) and inpool
        r["lost"] += (not c) and (not inpool)
        r["dependent_lost"] += d and (not c) and (not inpool)
    return r


def line(r):
    return "MATRIX-PAYCHAIN " + " ".join(f"{k}={v}" for k, v in r.items())


def main(argv):
    pool_mode = "--pool" in argv
    json_mode = "--json" in argv
    runs = [a for a in argv if a not in ("--pool", "--json")]
    arms = defaultdict(lambda: defaultdict(int))
    rc = 0
    for run in runs:
        r = classify(run)
        name = os.path.basename(os.path.normpath(run))
        if json_mode and not pool_mode:
            if r.get("pool_unknown"):
                print(f"matrix_paychain: {run}: A's pool at the end is unknown (a_pool_end.txt missing or a_pool_end.err "
                      f"present): {r['pool_unknown']} unconfirmed payments are neither lost nor pending", file=sys.stderr)
                rc = 3
                continue
            print(json.dumps(r))
            continue
        if not pool_mode:
            print(line(r))
            continue
        print(f"{name}: {line(r)}")
        a = arms[name.rsplit("-", 1)[0]]
        a["runs"] += 1
        a["runs_with_loss"] += r["lost"] > 0
        for k, v in r.items():
            a[k] += v
    for arm, a in sorted(arms.items()):
        print(f"ARM {arm}: runs {a['runs']}, runs with a lost payment {a['runs_with_loss']}; accepted {a['accepted']}, "
              f"dependent {a['dependent']} (confirmed {a['dependent_confirmed']}, lost {a['dependent_lost']}); "
              f"confirmed {a['confirmed']}, lost {a['lost']}, pending {a['pending']}, unknown inputs {a['unknown_inputs']}"
              + (f"; pool unknown {a['pool_unknown']}" if "pool_unknown" in a else ""))
    return rc


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
