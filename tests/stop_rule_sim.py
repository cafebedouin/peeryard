#!/usr/bin/env python3
"""stop_rule_sim.py: the numbers behind the fork-convergence stop rule in diffrun/README.md, reproducible.

Model: each pair is one base run and one candidate run; each run "switches" independently with probability
p (base) or q (candidate). Verdict as in diffrun (all runs VALID): AGAINST if any candidate run did not switch;
else NULL if base had fewer than K non-switches; else SUPPORTS. The sequential rule stops after pair i >= n_min
once base has >= K non-switches, or at max_n. A false SUPPORTS is SUPPORTS when the candidate is no better than
base (q = p).

  python3 tests/stop_rule_sim.py [--trials 200000] [--seed 1]
"""
import argparse, random

def one(rng, p, q, n_min, max_n, k, sequential):
    base_fail = 0; cand_fail = 0; pairs = 0
    for i in range(1, max_n + 1):
        pairs = i
        if rng.random() >= p: base_fail += 1
        if rng.random() >= q: cand_fail += 1
        if sequential and i >= n_min and base_fail >= k: break
        if not sequential and i >= n_min: break
    if cand_fail > 0: v = "AGAINST"
    elif base_fail < k: v = "NULL"
    else: v = "SUPPORTS"
    return v, pairs

def rate(rng, trials, **kw):
    sup = 0; tot_pairs = 0
    for _ in range(trials):
        v, pairs = one(rng, **kw); sup += v == "SUPPORTS"; tot_pairs += pairs
    return sup / trials, tot_pairs / trials

def main():
    ap = argparse.ArgumentParser(); ap.add_argument("--trials", type=int, default=200000); ap.add_argument("--seed", type=int, default=1)
    a = ap.parse_args(); rng = random.Random(a.seed)
    rules = [("sequential min 8, cap 12, K=2 (shipped)", dict(n_min=8, max_n=12, k=2, sequential=True)),
             ("sequential min 3, cap 12, K=2", dict(n_min=3, max_n=12, k=2, sequential=True)),
             ("fixed n=3, K=2", dict(n_min=3, max_n=3, k=2, sequential=False)),
             ("fixed n=6, K=2", dict(n_min=6, max_n=6, k=2, sequential=False)),
             ("fixed n=3, K=1", dict(n_min=3, max_n=3, k=1, sequential=False)),
             ("fixed n=6, K=1", dict(n_min=6, max_n=6, k=1, sequential=False))]
    print(f"trials={a.trials} seed={a.seed}")
    print(f"{'rule':<42} {'p':>5} {'false SUPPORTS (q=p)':>21} {'SUPPORTS (q=1)':>15} {'mean pairs (q=p)':>17}")
    for name, kw in rules:
        for p in (0.35, 0.57, 0.70, 0.85):
            fs, mp = rate(rng, a.trials, p=p, q=p, **kw)
            tp, _ = rate(rng, a.trials, p=p, q=1.0, **kw)
            print(f"{name:<42} {p:>5.2f} {fs:>20.1%} {tp:>15.1%} {mp:>17.1f}")

if __name__ == "__main__":
    main()
