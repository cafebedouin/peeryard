"""matrix_paychain.py <run dir> [...] [--pool]: what happened to the payments of rig/examples/matrix-paychain.sh.
Reads payments.jsonl ({id, inputs, outputs} per accepted payment, in send order), confirmed.jsonl (the payments found
in a block of B's chain) and a_pool_end.txt (A's pool at the end), from <run dir> or <run dir>/out.
  dependent  an input is an output of an earlier payment of the same run (it spends unconfirmed change)
  lost       neither confirmed nor in A's pool at the end
  pending    not confirmed, still in A's pool
One line per run in the hook's format; with --pool, one line per arm (a run dir's basename up to its last '-'),
summing the runs, and the runs with at least one lost payment. Standard library only."""
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
    pool = set(open(pp).read().split()) if pp else set()
    made = set()
    r = dict(accepted=len(pays), dependent=0, confirmed=0, dependent_confirmed=0, lost=0, dependent_lost=0,
             pending=0, unknown_inputs=0)
    for p in pays:
        if p.get("inputs") is None:
            r["unknown_inputs"] += 1
        d = any(i in made for i in (p.get("inputs") or []))
        made.update(p.get("outputs") or [])
        c, inpool = p["id"] in conf, p["id"] in pool
        r["dependent"] += d
        r["confirmed"] += c
        r["dependent_confirmed"] += d and c
        r["pending"] += (not c) and inpool
        r["lost"] += (not c) and (not inpool)
        r["dependent_lost"] += d and (not c) and (not inpool)
    return r


def line(r):
    return "MATRIX-PAYCHAIN " + " ".join(f"{k}={v}" for k, v in r.items())


def main(argv):
    pool_mode = "--pool" in argv
    runs = [a for a in argv if a != "--pool"]
    arms = defaultdict(lambda: defaultdict(int))
    for run in runs:
        r = classify(run)
        name = os.path.basename(os.path.normpath(run))
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
              f"confirmed {a['confirmed']}, lost {a['lost']}, pending {a['pending']}, unknown inputs {a['unknown_inputs']}")


if __name__ == "__main__":
    main(sys.argv[1:])
