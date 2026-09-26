#!/usr/bin/env python3
"""aa_pool_test.py: the exact interval against published Clopper-Pearson values, and the pooling on the committed
fork-convergence A/A example (8 of 16 switched; its README quotes the exact 95% interval 0.25-0.75)."""
import os, subprocess, sys
HERE = os.path.dirname(os.path.abspath(__file__)); ROOT = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(ROOT, "diffrun"))
from aa_pool import clopper_pearson

known = {(0, 10): (0.0, 0.3085), (10, 10): (0.6915, 1.0), (5, 10): (0.1871, 0.8129), (1, 20): (0.0013, 0.2487)}
for (k, n), (lo, hi) in known.items():
    got = clopper_pearson(k, n)
    assert abs(got[0] - lo) < 1e-3 and abs(got[1] - hi) < 1e-3, f"{k}/{n}: {got} != {(lo, hi)}"
out = subprocess.run([sys.executable, os.path.join(ROOT, "diffrun", "aa_pool.py"), "--when", "switched==true",
                      os.path.join(ROOT, "diffrun", "examples", "fork-convergence-aa-6.0.6", "verdict.json")],
                     capture_output=True, text=True, check=True).stdout
assert "8/16 = 0.50, exact 95% interval 0.25-0.75" in out, out
print("aa_pool_test: ok")
