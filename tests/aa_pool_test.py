#!/usr/bin/env python3
"""aa_pool_test.py: the exact interval against published Clopper-Pearson values, and the pooling on the committed
fork-convergence A/A example (8 of 16 switched; its README quotes the exact 95% interval 0.25-0.75); two copies of it
pool, and a copy with other jars or another env is refused (shard_identity, mirrored from diffrun/lib/diffrun.jq)."""
import json, os, subprocess, sys, tempfile
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

EX = os.path.join(ROOT, "diffrun", "examples", "fork-convergence-aa-6.0.6", "verdict.json")
def pool(*files):
    return subprocess.run([sys.executable, os.path.join(ROOT, "diffrun", "aa_pool.py"), "--when", "switched==true", *files],
                          capture_output=True, text=True)
with tempfile.TemporaryDirectory() as d, open(EX) as fh:
    v = json.load(fh)
    def copy(name, edit=None):
        w = json.loads(json.dumps(v))
        if edit: edit(w)
        p = os.path.join(d, name)
        with open(p, "w") as o: json.dump(w, o)
        return p
    r = pool(EX, copy("same.json"))
    assert r.returncode == 0 and "16/32 = 0.50" in r.stdout, (r.returncode, r.stdout, r.stderr)
    for name, edit in [("cand", lambda w: w["jars"]["candidate"].update(jar_sha256="0" * 64)),
                       ("both", lambda w: [w["jars"][x].update(jar_sha256="0" * 64) for x in ("base", "candidate")]),
                       ("appver", lambda w: w["jars"]["base"].update(expected_app_version="9.9.9")),
                       ("env", lambda w: w["provenance"]["env"].update(DELTA=9))]:
        r = pool(EX, copy(name + ".json", edit))
        assert r.returncode != 0 and "differ in jars or env" in r.stderr, (name, r.returncode, r.stdout, r.stderr)
    # valid JSON that is not a verdict object: refused by name, no traceback
    for name, text in [("list.json", "[]"), ("num.json", "3"), ("runs.json", '{"same_jar": true, "runs": 5}')]:
        with open(os.path.join(d, name), "w") as o: o.write(text)
        r = pool(os.path.join(d, name))
        assert r.returncode != 0 and "is not a verdict.json" in r.stderr and "Traceback" not in r.stderr, (name, r.stderr)
    # the Python mirror agrees with the jq definition pool.sh uses
    jq = subprocess.run(["jq", "-cS", "-L", os.path.join(ROOT, "diffrun", "lib"), 'include "diffrun"; shard_identity', EX],
                        capture_output=True, text=True, check=True).stdout.strip()
    from aa_pool import shard_identity
    assert json.loads(jq) == shard_identity(v), (jq, shard_identity(v))
print("aa_pool_test: ok")
