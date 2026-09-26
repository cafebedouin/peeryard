#!/usr/bin/env python3
"""aa_pool.py: pool A/A runs from several diffrun verdict.json files (shards run on separate hosts) and report, per
boolean or numeric condition, how many VALID runs meet it, with an exact (Clopper-Pearson) 95% interval.

  python3 diffrun/aa_pool.py --when 'switched==false' shard1/verdict.json shard2/verdict.json ...

Every file must be an A/A control (same_jar true) of one scenario; both roles count, since they ran the same jar.
Standard library only."""
import argparse, json, math, sys

OPS = {"==": lambda a, b: a == b, "!=": lambda a, b: a != b, ">": lambda a, b: a > b, ">=": lambda a, b: a >= b,
       "<": lambda a, b: a < b, "<=": lambda a, b: a <= b}

def parse_when(s):
    for op in ("==", "!=", ">=", "<=", ">", "<"):
        if op in s:
            k, v = s.split(op, 1)
            return k.strip(), op, json.loads(v.strip())
    raise SystemExit(f"aa_pool: cannot parse condition {s!r}")

def binom_cdf(k, n, p):
    if k < 0: return 0.0
    if k >= n: return 1.0
    return sum(math.comb(n, i) * p**i * (1 - p)**(n - i) for i in range(k + 1))

def clopper_pearson(k, n, alpha=0.05):
    def solve(f):  # f decreasing in p; find p with f(p) = alpha/2 by bisection
        lo, hi = 0.0, 1.0
        for _ in range(100):
            mid = (lo + hi) / 2
            if f(mid) > alpha / 2: lo = mid
            else: hi = mid
        return (lo + hi) / 2
    upper = 1.0 if k == n else solve(lambda p: binom_cdf(k, n, p))           # P(X <= k | p) = alpha/2
    lower = 0.0 if k == 0 else 1 - solve(lambda q: binom_cdf(n - k, n, q))  # by symmetry: 1 - upper(n-k, n)
    return lower, upper

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--when", action="append", required=True, help="metric condition, e.g. switched==false")
    ap.add_argument("files", nargs="+")
    a = ap.parse_args()
    runs, scen = [], set()
    for f in a.files:
        v = json.load(open(f))
        if not v.get("same_jar"):
            sys.exit(f"aa_pool: {f} is not an A/A control (same_jar is not true)")
        scen.add(v.get("scenario", {}).get("name") if isinstance(v.get("scenario"), dict) else v.get("scenario"))
        runs += [dict(r, _file=f) for r in v.get("runs", [])]
    if len(scen) != 1:
        sys.exit(f"aa_pool: files mix scenarios: {sorted(map(str, scen))}")
    valid = [r for r in runs if r.get("class") == "VALID"]
    print(f"scenario {scen.pop()}: {len(a.files)} shard(s), {len(runs)} runs, {len(valid)} VALID "
          f"({len(runs) - len(valid)} not: {sorted({r.get('class') for r in runs if r.get('class') != 'VALID'})})")
    for w in a.when:
        key, op, val = parse_when(w)
        have = [r for r in valid if key in (r.get("metrics") or {})]
        k = sum(1 for r in have if OPS[op](r["metrics"][key], val))
        n = len(have)
        if n == 0:
            print(f"  {w}: no VALID run carries {key!r}"); continue
        lo, hi = clopper_pearson(k, n)
        print(f"  {w}: {k}/{n} = {k/n:.2f}, exact 95% interval {lo:.2f}-{hi:.2f}")

if __name__ == "__main__":
    main()
