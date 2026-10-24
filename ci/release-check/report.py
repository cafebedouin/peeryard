#!/usr/bin/env python3
"""report.py: the release check's summary table and its draft results note, from the jobs' artifacts.

  python3 ci/release-check/report.py --art <downloaded artifacts dir> [--jobs jobs.json] [--run-url URL]
                                     [--recorded ci/release-check/recorded-rates.json] --out <dir>

Reads <art>/rc-scope/scope.json, <art>/rc-plan/plan.json, <art>/rc-jars/build-info.json, every
<art>/ex-*/result.json (one per example job) and every <art>/rate-<scenario>-<shard>/verdict.json (diffrun, base =
baseline, candidate = candidate). Rates are pooled per role over the VALID runs, with an exact (Clopper-Pearson) 95%
interval (diffrun/aa_pool.py). A rate is marked as changed when the candidate's interval does not contain the
baseline's point estimate from the same dispatch; that flags a difference to look at, it is not a verdict. The
baseline's own interval is also checked for overlap with a rate recorded earlier for that release (recorded-rates.json),
and Fisher's exact test (two-sided) on the two roles' counts is reported beside the flag.

Writes <out>/summary.md (for the step summary), <out>/release-check.md (a draft note: facts only, for a person to
review) and <out>/rates.json. A missing artifact is reported as such, never filled in."""
import argparse, glob, json, os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(HERE)), "diffrun"))
from aa_pool import OPS, clopper_pearson, parse_when  # noqa: E402

LINE_RE = re.compile(r"^rig (\S+): (PASS|FAIL|SKIP)( \(experimental\))?(?: \((.*)\))?")


def load(path, default=None):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, json.JSONDecodeError):
        return default


def status(line):
    """'rig x: PASS (marker)' -> ('PASS', ''), 'rig x: FAIL (why; see ...)' -> ('FAIL', 'why')."""
    if not line:
        return "NO RESULT", ""
    m = LINE_RE.match(line)
    if not m:
        return "NO RESULT", line[:120]
    word, exp, detail = m.group(2), bool(m.group(3)), (m.group(4) or "")
    detail = detail.split("; see ")[0]
    detail = re.sub(r"^(FAIL|PASS)(; |$)", "", detail).replace("; not counted", "").replace("not counted", "").strip("; ")
    if word == "FAIL" and exp:
        return "FAIL (experimental)", detail
    return word, ("" if word == "PASS" else detail)


def fmt_rate(k, n):
    if n == 0:
        return "no VALID runs"
    lo, hi = clopper_pearson(k, n)
    return f"{k}/{n} = {k / n:.2f} [{lo:.2f}, {hi:.2f}]"


def fisher_two_sided(k1, n1, k2, n2):
    """Fisher's exact test on the 2x2 table (k1, n1-k1; k2, n2-k2): the two-sided p-value (the sum of the
    hypergeometric probabilities of every table with the same margins that is no more likely than the observed one)."""
    from math import comb
    K, N = k1 + k2, n1 + n2
    if n1 == 0 or n2 == 0:
        return None
    def pr(x):
        return comb(K, x) * comb(N - K, n1 - x) / comb(N, n1)
    lo, hi = max(0, K - n2), min(K, n1)
    p0 = pr(k1)
    return min(1.0, sum(pr(x) for x in range(lo, hi + 1) if pr(x) <= p0 * (1 + 1e-9)))


def pool(files, when):
    key, op, val = parse_when(when)
    per = {"base": [0, 0, 0], "candidate": [0, 0, 0]}   # k, n VALID, not VALID
    for f in files:
        v = load(f, {})
        for r in v.get("runs", []):
            role = r.get("role")
            if role not in per:
                continue
            if r.get("class") != "VALID" or key not in (r.get("metrics") or {}):
                per[role][2] += 1
                continue
            per[role][1] += 1
            per[role][0] += 1 if OPS[op](r["metrics"][key], val) else 0
    return per


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--art", required=True)
    ap.add_argument("--jobs", default="")
    ap.add_argument("--run-url", default="")
    ap.add_argument("--recorded", default=os.path.join(HERE, "recorded-rates.json"))
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)

    scope = load(os.path.join(a.art, "rc-scope", "scope.json"))
    plan = load(os.path.join(a.art, "rc-plan", "plan.json"), {})
    build = load(os.path.join(a.art, "rc-jars", "build-info.json"), {})
    recorded = load(a.recorded, {})
    jobs = load(a.jobs, []) if a.jobs else []
    if isinstance(jobs, dict):
        jobs = jobs.get("jobs", [])
    job_url = {j.get("name"): j.get("html_url") for j in jobs}
    if scope is None:
        sys.exit("report: no rc-scope/scope.json in the artifacts")
    cat = {c["name"]: c for c in scope["catalog"]}
    order = [c["name"] for c in scope["catalog"]]
    btag = scope["baseline"]["tag"]

    # ---- examples ----
    # one artifact per example job and attempt (a re-run job uploads under its attempt number); the latest counts,
    # the earlier ones are listed
    ex, earlier = {}, {}
    for f in sorted(glob.glob(os.path.join(a.art, "ex-*", "result.json"))):
        r = load(f)
        if not r:
            continue
        key = (r["name"], r["repeat"])
        old = ex.get(key)
        if old is None or r.get("attempt", 1) > old.get("attempt", 1):
            if old is not None:
                earlier.setdefault(key, []).append(old)
            ex[key] = r
        else:
            earlier.setdefault(key, []).append(r)
    planned = {}
    for e in plan.get("examples", []):
        planned.setdefault(e["name"], []).append(e["repeat"])
    rows = []
    for name in [n for n in order if n in planned]:
        got = {rep: ex[(name, rep)] for rep in planned[name] if (name, rep) in ex}
        cands, bases, links = [], [], []
        for rep in planned[name]:
            r = got.get(rep)
            jn = f"{name} ({rep})"
            links.append(f"[{rep}]({job_url[jn]})" if job_url.get(jn) else f"{rep}")
            if r is None:
                cands.append(("NO RESULT", "no artifact")); bases.append(("NO RESULT", "no artifact") if cat[name]["baseline_arm"] else None)
                continue
            cands.append(status(r.get("candidate")))
            bases.append(status(r.get("baseline")) if cat[name]["baseline_arm"] else None)
        prior = [f"attempt {o.get('attempt', 1)} of repeat {o['repeat']}: candidate {status(o.get('candidate'))[0]}"
                 + (f", baseline {status(o.get('baseline'))[0]}" if cat[name]["baseline_arm"] else "")
                 for rep in planned[name] for o in sorted(earlier.get((name, rep), []), key=lambda o: o.get("attempt", 1))]
        rows.append({"name": name, "covers": cat[name]["covers"], "part": cat[name]["part"],
                     "candidate": cands, "baseline": bases, "links": links, "earlier": prior})

    def cell(results):
        if not results or all(x is None for x in results):
            return "n/a (both jars in one run)"
        words = [x[0] for x in results if x is not None]
        if len(set(words)) == 1:
            s = words[0] if len(words) == 1 else f"{words[0]} x{len(words)}"
        else:
            s = ", ".join(words)
        why = "; ".join(sorted({x[1] for x in results if x is not None and x[1]}))
        return s + (f" ({why[:140]})" if why else "")

    # ---- rates ----
    rates = []
    for s in sorted({x["scenario"] for x in plan.get("shards", [])}, key=order.index):
        when = cat[s]["rate"].split()[0]
        latest = {}
        for f in glob.glob(os.path.join(a.art, f"rate-{s}-*", "verdict.json")):
            m = re.match(rf"rate-{re.escape(s)}-(\d+)(?:-a(\d+))?$", os.path.basename(os.path.dirname(f)))
            if m:
                k_, att = int(m.group(1)), int(m.group(2) or 1)
                if k_ not in latest or att > latest[k_][0]:
                    latest[k_] = (att, f)
        files = [latest[k_][1] for k_ in sorted(latest)]
        shards = [x for x in plan["shards"] if x["scenario"] == s]
        per = pool(files, when)
        (ck, cn, cx), (bk, bn, bx) = per["candidate"], per["base"]
        r = {"scenario": s, "condition": when, "shards_planned": len(shards), "shards_with_verdict": len(files),
             "pairs_planned": sum(x["pairs"] for x in shards),
             "candidate": {"k": ck, "n": cn, "not_valid": cx}, "baseline": {"k": bk, "n": bn, "not_valid": bx}}
        if cn and bn:
            lo, hi = clopper_pearson(ck, cn)
            r["candidate"]["interval"] = [lo, hi]
            r["baseline"]["interval"] = list(clopper_pearson(bk, bn))
            r["baseline_estimate"] = bk / bn
            r["changed"] = not (lo <= bk / bn <= hi)
            r["fisher_p"] = fisher_two_sided(ck, cn, bk, bn)
        rec = (recorded.get(btag) or {}).get(s)
        if rec and rec.get("when") == when and bn:
            blo, bhi = clopper_pearson(bk, bn)
            rlo, rhi = clopper_pearson(rec["k"], rec["n"])
            r["recorded"] = dict(rec, interval=[rlo, rhi])
            r["reproduces_recorded"] = blo <= rhi and rlo <= bhi   # the two intervals overlap
        r["links"] = [f"[{x['shard']}]({job_url[f'rate {s} shard {x['shard']}']})" if job_url.get(f"rate {s} shard {x['shard']}")
                      else str(x["shard"]) for x in shards]
        rates.append(r)
    json.dump(rates, open(os.path.join(a.out, "rates.json"), "w"), indent=1)

    # ---- the step summary ----
    cand, base = scope["candidate"], scope["baseline"]
    head = [f"## Release check: {cand['ref']} (`{cand['sha'][:12]}`) against {btag}", ""]
    if a.run_url:
        head.append(f"Run: {a.run_url}")
    if build:
        head.append(f"Candidate jar: appVersion `{build.get('candidate_version', '?')}`, sha256 `{build.get('candidate_sha256', '?')[:16]}…`; "
                    f"baseline jar: {btag} release asset, sha256 `{build.get('baseline_sha256', '?')[:16]}…` "
                    f"({'matches' if build.get('baseline_sha256_checked') else 'NOT checked against'} the release's .sha256 asset)")
    head.append(f"Parts: {', '.join(plan.get('parts', []))}; repeats {plan.get('repeats', '?')}; rate pairs {plan.get('rate_pairs', '?')} per scenario.")
    head.append("")
    t = ["| scenario | candidate | baseline or rate | jobs |", "|---|---|---|---|"]
    for r in rows:
        t.append(f"| {r['name']} | {cell(r['candidate'])} | {cell(r['baseline'])} | {' '.join(r['links'])} |")
    for r in rates:
        c, b = r["candidate"], r["baseline"]
        flag = "" if "changed" not in r else (" **interval excludes the baseline estimate**" if r["changed"] else "")
        fp = "" if r.get("fisher_p") is None else f" (Fisher p {r['fisher_p']:.3f})"
        t.append(f"| {r['scenario']} (`{r['condition']}`) | {fmt_rate(c['k'], c['n'])}{flag}{fp} | {fmt_rate(b['k'], b['n'])} | {' '.join(r['links'])} |")
    summary = head + t + [""]
    open(os.path.join(a.out, "summary.md"), "w").write("\n".join(summary) + "\n")

    # ---- the draft note ----
    n = []
    n += [f"# Release check: {cand['ref']} against {btag} (draft)", ""]
    n += ["Draft results note, written by the workflow from the run's artifacts. Facts only; it says what ran and what "
          "each run reported. Review every line against the linked jobs before using any of it.", ""]
    n += ["## What ran", ""]
    if a.run_url:
        n.append(f"- Workflow run: {a.run_url}, on GitHub-hosted `ubuntu-24.04` runners (one runner class; every rate "
                 "below is a rate on that class).")
    n.append(f"- Candidate: `{cand['ref']}` at `{cand['sha']}`, built from source with `diffrun/build.sh` "
             f"(appVersion `{build.get('candidate_version', '?')}`, jar sha256 `{build.get('candidate_sha256', '?')}`).")
    n.append(f"- Baseline: release {btag} (`{base['sha']}`), its `ergo-*.jar` asset, sha256 `{build.get('baseline_sha256', '?')}`"
             + (", equal to the release's `.jar.sha256` asset." if build.get("baseline_sha256_checked") else "."))
    nprod = [p for p in scope["paths"] if p["scenarios"]]
    n.append(f"- Scope: {len(scope['commits'])} commits and {len(scope['prs'])} pull requests in {btag}..{cand['sha'][:12]}; "
             f"{len(scope['paths'])} changed paths, {len(nprod)} of them mapped to a scenario "
             f"(the full list is the `rc-scope` artifact).")
    sel = plan.get("scenarios", [])
    n.append(f"- Scenarios in this dispatch: {', '.join(sel) or 'none'} ({', '.join(plan.get('parts', []))}).")
    n.append("")
    if rows:
        n += ["## Multi-node scenarios and upgrade path", "",
              "Each example ran on the candidate and, where it uses one jar, on the baseline in the same job "
              "(`rig/run-suite.sh`: PASS needs the example's marker and the rig's exit status 0).", "",
              "| scenario | what it checks | candidate | baseline |", "|---|---|---|---|"]
        for r in rows:
            n.append(f"| {r['name']} | {r['covers']} | {cell(r['candidate'])} | {cell(r['baseline'])} |")
        n.append("")
        for r in rows:
            for e in r["earlier"]:
                n.append(f"- {r['name']}: an earlier {e} (the table shows the latest attempt).")
        if any(r["earlier"] for r in rows):
            n.append("")
    if rates:
        n += ["## Rates, candidate against baseline", "",
              "Pairs of runs (baseline, candidate; order counterbalanced), pooled per role over the VALID runs. "
              "Intervals are exact 95% (Clopper-Pearson). \"Excludes\" means the candidate's interval does not contain "
              "the baseline's point estimate from the same run: a difference to look at, not a verdict. Fisher's exact test "
              "(two-sided) on the same counts is given beside it.", "",
              "| scenario | condition | candidate | baseline | candidate interval excludes the baseline estimate | Fisher p |",
              "|---|---|---|---|---|---|"]
        for r in rates:
            c, b = r["candidate"], r["baseline"]
            ex_ = "-" if "changed" not in r else ("yes" if r["changed"] else "no")
            fp = "-" if r.get("fisher_p") is None else f"{r['fisher_p']:.3f}"
            n.append(f"| {r['scenario']} | `{r['condition']}` | {fmt_rate(c['k'], c['n'])} | {fmt_rate(b['k'], b['n'])} | {ex_} | {fp} |")
        n.append("")
        for r in rates:
            nv = r["candidate"]["not_valid"] + r["baseline"]["not_valid"]
            extra = f"; {nv} run(s) not VALID, not counted" if nv else ""
            n.append(f"- {r['scenario']}: {r['shards_with_verdict']} of {r['shards_planned']} shards returned a verdict "
                     f"({r['pairs_planned']} pairs planned){extra}.")
            if "recorded" in r:
                rec = r["recorded"]
                n.append(f"  The baseline's rate recorded earlier for {btag}: {fmt_rate(rec['k'], rec['n'])} ({rec['kind']}, {rec['source']}); "
                         f"this run's baseline interval {'overlaps' if r['reproduces_recorded'] else 'does not overlap'} it.")
        n.append("")
    n += ["## Not covered by this check", "",
          "- A full mainnet sync, or any run on mainnet or testnet data: a hosted job has 6 hours and about 14 GB of disk.",
          "- Unit, wallet, core and integration tests: upstream CI runs them on the candidate.",
          "- Chain sizes, block contents and timing of a public network: every scenario runs on a private devnet of 1-4 nodes "
          "with small blocks and short block intervals.",
          "- The Matrix (weak-blocks) line and the Rust nodes.",
          "- Behaviour no scenario stages; each scenario's own limits are in rig/README.md and diffrun/README.md."]
    for p in scope["paths"]:
        if p["mapped"] and not p["scenarios"] and not re.search(r"(^|/)src/(test|it)/", p["path"]):
            n.append(f"- `{p['path']}`: {'; '.join(p['notes'])}.")
    for p in scope["unmapped"]:
        n.append(f"- `{p}`: no row of the path map covers it.")
    n += ["", "## Reds", "",
          "(For a person to fill in after reading the logs: each red re-run once, then recorded as also red on the baseline, "
          "a known flake with where it is known, or environmental with the log line. The workflow does not classify.)", ""]
    open(os.path.join(a.out, "release-check.md"), "w").write("\n".join(n) + "\n")
    print("\n".join(summary))


if __name__ == "__main__":
    main()
