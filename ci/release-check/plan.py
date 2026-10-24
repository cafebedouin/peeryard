#!/usr/bin/env python3
"""plan.py: the job plan of one release-check dispatch, from the scope and the inputs; refuses a plan over the job cap.

  python3 ci/release-check/plan.py --scope scope.json --scenarios auto|core|"<name> ..." --parts suite,upgrade,rates
                                   --repeats N --rate-pairs N [--max-jobs 30] [--out plan.json]

Examples (parts suite and upgrade) become one job per example and repeat; the job runs the candidate and, when the
catalog's baseline_arm is 1, the baseline after or before it (the order alternates by repeat). Rate scenarios become
shards of at most the catalog's pairs-per-shard pairs, together rate-pairs pairs per scenario (base = baseline,
candidate = candidate). The total counts the plan, build and summary jobs too. Prints the plan; with --github-output,
also writes the matrices as step outputs."""
import argparse, json, math, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))


def suite_rows():
    rows = {}
    for path in (os.path.join(ROOT, "rig/examples/suite.tsv"), os.path.join(HERE, "extra-suite.tsv")):
        with open(path) as f:
            for line in f:
                if line.startswith("#") or not line.strip():
                    continue
                c = line.rstrip("\n").split("\t")
                if len(c) == 5:
                    rows[c[0]] = {"marker": c[1], "timeout": int(c[2]), "env": c[3], "needs": c[4]}
    return rows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--scope", required=True)
    ap.add_argument("--scenarios", default="auto")
    ap.add_argument("--parts", default="suite,upgrade,rates")
    ap.add_argument("--repeats", default="1")
    ap.add_argument("--rate-pairs", default="12")
    ap.add_argument("--max-jobs", type=int, default=30)
    ap.add_argument("--out", default="plan.json")
    ap.add_argument("--github-output", action="store_true")
    a = ap.parse_args()

    def fail(msg):
        print(f"::error::{msg}")
        sys.exit(1)

    scope = json.load(open(a.scope))
    catalog = {c["name"]: c for c in scope["catalog"]}
    order = [c["name"] for c in scope["catalog"]]
    if not (a.repeats.isdigit() and 1 <= int(a.repeats) <= 3):
        fail("repeats: 1-3")
    if not (a.rate_pairs.isdigit() and 1 <= int(a.rate_pairs) <= 40):
        fail("rate_pairs: 1-40")
    repeats, rate_pairs = int(a.repeats), int(a.rate_pairs)
    parts = [p.strip() for p in a.parts.replace(" ", ",").split(",") if p.strip()]
    if not parts or any(p not in ("suite", "upgrade", "rates") for p in parts):
        fail("parts: a comma-separated subset of suite, upgrade, rates")
    words = a.scenarios.split()
    if words == ["auto"]:
        chosen = list(scope["selected"])
    elif words == ["core"]:
        chosen = [n for n in order if catalog[n]["core"]]
    else:
        bad = [w for w in words if w not in catalog]
        if bad or not words:
            fail(f"scenarios: auto, core, or names from ci/release-check/catalog.tsv (unknown: {' '.join(bad) or 'none given'})")
        chosen = [n for n in order if n in words]
    chosen = [n for n in chosen if catalog[n]["part"] in parts]
    rows = suite_rows()
    examples, shards = [], []
    for n in chosen:
        c = catalog[n]
        if c["part"] in ("suite", "upgrade"):
            if n not in rows:
                fail(f"{n}: no row in rig/examples/suite.tsv or ci/release-check/extra-suite.tsv")
            arms = 2 if c["baseline_arm"] else 1
            for r in range(1, repeats + 1):
                examples.append({"name": n, "repeat": r, "baseline_arm": c["baseline_arm"],
                                 "first": "candidate" if r % 2 == 1 or not c["baseline_arm"] else "baseline",
                                 "minutes": math.ceil(arms * rows[n]["timeout"] / 60) + 15})
        else:
            when, pps = c["rate"].split()
            pps = int(pps)
            man = json.load(open(os.path.join(ROOT, "diffrun/scenarios", f"{n}.json")))
            per_run = (man.get("timeout_seconds", 900) + (man.get("precheck_timeout_seconds", 300) if "precheck" in man else 0)) / 60
            k, left = 1, rate_pairs
            while left > 0:
                p = min(pps, left)
                shards.append({"scenario": n, "shard": k, "pairs": p, "when": when,
                               "minutes": min(350, math.floor(2 * p * per_run) + 30)})
                k, left = k + 1, left - p
    total = 3 + len(examples) + len(shards)
    plan = {"scenarios": chosen, "parts": parts, "repeats": repeats, "rate_pairs": rate_pairs,
            "examples": examples, "shards": shards, "jobs": total, "max_jobs": a.max_jobs}
    json.dump(plan, open(a.out, "w"), indent=1)
    print(f"plan: {len(examples)} example jobs, {len(shards)} rate shards, {total} jobs in all (cap {a.max_jobs})")
    print("  examples: " + (" ".join(sorted({e['name'] for e in examples}, key=order.index)) or "none"))
    print("  rates: " + (" ".join(f"{s['scenario']}#{s['shard']}x{s['pairs']}" for s in shards) or "none"))
    if not chosen:
        fail("nothing selected: the scenarios and parts inputs leave no scenario")
    if total > a.max_jobs:
        fail(f"{total} jobs exceed the cap of {a.max_jobs}: split the run across dispatches (parts=suite,upgrade then "
             f"parts=rates, or fewer scenarios, repeats or rate_pairs)")
    if a.github_output:
        with open(os.environ["GITHUB_OUTPUT"], "a") as f:
            f.write(f"examples={json.dumps(examples, separators=(',', ':'))}\n")
            f.write(f"shards={json.dumps(shards, separators=(',', ':'))}\n")
            f.write(f"n_examples={len(examples)}\nn_shards={len(shards)}\njobs={total}\n")


if __name__ == "__main__":
    main()
