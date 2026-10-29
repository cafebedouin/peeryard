"""browser/compare.py: per tx, per input, per step, the browser verdict vs the Node verdict of the same build.

usage: python3 -I compare.py <node results dir> <browser results dir> [--json <out.json>]
Reads results-V{0,1,2}.json (../run.js, Node) and results-browser-V{0,1,2}.json (run_browser.js). Prints:
controls, per-version counts, verdict diffs, error-string diffs, stack/trap/crash scan, stack-probe budget, and
== checks: exit 1 if any check fails (a control, a verdict diff, a stack/trap/crash/console hit, a page-side corpus
sha256 mismatch, a different tx list). Error-string differences are printed, not checked.
A "verdict" is the pass/fail outcome of a step (a: pass + its three sub-results; b: pass + returned value;
c: pass; d: applicable + pass + the error's input index / at-P2PK flag). Error strings are compared separately.
"""
import json
import re
import sys
from collections import Counter

NODE_DIR, BR_DIR = sys.argv[1], sys.argv[2]
JSON_OUT = sys.argv[sys.argv.index("--json") + 1] if "--json" in sys.argv else None
CHECKS = []  # (name, ok, detail)


def check(name, ok, detail=""):
    CHECKS.append((name, bool(ok), str(detail)))
STACK_RE = re.compile(r"RangeError|Maximum call stack|unreachable|RuntimeError", re.I)


def load(p):
    with open(p) as f:
        return json.load(f)


def verdicts(r):
    v = {}
    for x in r.get("inputs", []):
        i = x["index"]
        a = x["a"]
        v[f"in{i}.a"] = (a["pass"], a.get("from_base16_bytes"), a.get("roundtrip"), a.get("template_bytes"))
        v[f"in{i}.b"] = (x["b"]["pass"], x["b"].get("value"), bool(x["b"].get("skipped")))
    if "c" in r:
        v["c"] = (r["c"]["pass"], bool(r["c"].get("skipped")))
    if "d" in r:
        d = r["d"]
        v["d"] = (d["applicable"], d["pass"], d.get("err_input_index"), d.get("err_at_p2pk"), d.get("err_mentions_parse"),
                  d.get("outcome"))
    v["setup"] = tuple(sorted((k, val) for k, val in r.get("setup", {}).items() if not k.endswith("_err")))
    v["crashed"] = bool(r.get("child_crashed") or r.get("page_failed"))
    return v


def errors(r):
    e = {}
    for x in r.get("inputs", []):
        e[f"in{x['index']}.a"] = x["a"].get("err")
        e[f"in{x['index']}.b"] = x["b"].get("err")
    for s in ("c", "d"):
        if s in r:
            e[s] = r[s].get("err")
    for k, val in r.get("setup", {}).items():
        if k.endswith("_err"):
            e["setup." + k] = val
    return e


def stack_hits(r):
    """Every place a stack error / wasm trap / crash could show in one browser tx record."""
    hits = []
    for x in r.get("inputs", []):
        for s in ("a", "b"):
            if x[s].get("range_error"):
                hits.append(f"in{x['index']}.{s}.range_error")
            if x[s].get("err") and STACK_RE.search(x[s]["err"]):
                hits.append(f"in{x['index']}.{s}.err~stack/trap: {x[s]['err'][:120]}")
    for s in ("c", "d"):
        if s in r and r[s].get("range_error"):
            hits.append(f"{s}.range_error")
        if s in r and r[s].get("err") and STACK_RE.search(r[s]["err"]):
            hits.append(f"{s}.err~stack/trap: {r[s]['err'][:120]}")
    if r.get("setup", {}).get("range_error"):
        hits.append("setup.range_error")
    b = r.get("browser", {})
    if r.get("page_failed"):
        hits.append("page_failed")
    if b.get("crashed"):
        hits.append("page crashed")
    if b.get("page_error"):
        hits.append(f"page_error: {b['page_error'][:160]}")
    if b.get("range_error_page"):
        hits.append("page range_error")
    if b.get("driver_error"):
        hits.append(f"driver_error: {b['driver_error'][:160]}")
    for pe in b.get("page_errors", []):
        hits.append(f"pageerror event: {pe[:160]}")
    for c in b.get("console", []):
        if c["type"] in ("error", "warning", "assert"):
            hits.append(f"console.{c['type']}: {c['text'][:160]}")
    for rf in b.get("request_failed", []):
        hits.append(f"request_failed: {rf[:160]}")
    return hits


def counts(run):
    res = run["results"]
    ins = [x for r in res for x in r.get("inputs", [])]
    dd = [r for r in res if r.get("d", {}).get("applicable")]
    s354 = [r for r in dd if r.get("shape354")]
    return {
        "txs": len(res), "inputs": len(ins),
        "a": sum(x["a"]["pass"] for x in ins), "b": sum(x["b"]["pass"] for x in ins),
        "c": sum(r.get("c", {}).get("pass", False) for r in res),
        "d_applicable": len(dd), "d": sum(r["d"]["pass"] for r in dd),
        "d354_applicable": len(s354), "d354": sum(r["d"]["pass"] for r in s354),
    }


def by_contract(run):
    c = Counter()
    n = Counter()
    for r in run["results"]:
        for x in r.get("inputs", []):
            n[x["contract"]] += 1
            c[(x["contract"], "a")] += x["a"]["pass"]
            c[(x["contract"], "b")] += x["b"]["pass"]
    return n, c


print("== runs")
runs = {}
for V in ("V0", "V1", "V2"):
    node = load(f"{NODE_DIR}/results-{V}.json")
    br = load(f"{BR_DIR}/results-browser-{V}.json")
    runs[V] = (node, br)
    print(f"{V} node:    {node['lib_name']}@{node['lib_version']} wasm={node['wasm_sha256']} corpus={node['corpus_sha256']} {node['node']}")
    print(f"{V} browser: {br['lib_name']}@{br['lib_version']} wasm={br['wasm_sha256']} corpus={br['corpus_sha256']} "
          f"chromium={br['runtime']['browser_version']} shims={br['shims']}")
    pc = [r.get("browser", {}).get("page_corpus_sha256_ok") for r in br["results"]]
    li = Counter(json.dumps({k: v for k, v in (r.get("browser", {}).get("load_info") or {}).items() if k != "base"}, sort_keys=True)
                 for r in br["results"])
    print(f"   page-side corpus sha256 ok: {sum(1 for x in pc if x)}/{len(pc)}; load_info: {dict(li)}")
    check(f"{V} page-side corpus sha256 = driver's, every page", len(pc) > 0 and all(pc), f"{sum(1 for x in pc if x)}/{len(pc)}")
    check(f"{V} browser and node read the same corpus", br["corpus_sha256"] == node["corpus_sha256"], br["corpus_sha256"])
    check(f"{V} browser run used no API shims", br["shims"] == [], br["shims"])

print("\n== controls")
for V in ("V0", "V1", "V2"):
    node, br = runs[V]
    for tag, run in (("node", node), ("browser", br)):
        pool = [x for r in run["results"] for x in r.get("inputs", []) if x["contract"] == "LD_LiquidityPool"]
        pool_ncb = sum(1 for x in pool if not x["a"]["pass"] and "NonConsumedBytes" in (x["a"].get("err") or ""))
        p2pk = [x for r in run["results"] for x in r.get("inputs", []) if x["contract"] == "P2PK"]
        p2pk_ok = sum(1 for x in p2pk if x["b"].get("value") is True)
        sig = [r for r in run["results"] if "control_sigusd_bank" in r.get("sets", [])]
        sig_ok = all(all(x["a"]["pass"] and x["b"]["pass"] for x in r["inputs"]) and r["c"]["pass"] for r in sig) and len(sig) == 1
        print(f"{V} {tag:8s} pool tree fails a with NonConsumedBytes: {pool_ncb}/{len(pool)}   "
              f"P2PK b verify true: {p2pk_ok}/{len(p2pk)}   SigUSD control a-c: {'yes' if sig_ok else 'NO'}")
        if tag == "browser":
            if V == "V0":
                check("V0 browser: pool tree fails step a with NonConsumedBytes on every pool input",
                      len(pool) > 0 and pool_ncb == len(pool), f"{pool_ncb}/{len(pool)}")
            check(f"{V} browser: every P2PK input verifies true", len(p2pk) > 0 and p2pk_ok == len(p2pk), f"{p2pk_ok}/{len(p2pk)}")
            check(f"{V} browser: SigUSD control passes a-c", sig_ok)

print("\n== per version counts (a, b over inputs; c over txs; d over P2PK-bearing txs; d354 = pool+P2PK shape)")
for V in ("V0", "V1", "V2"):
    node, br = runs[V]
    print(f"{V} node:    {counts(node)}")
    print(f"{V} browser: {counts(br)}")

print("\n== per version, per contract (a / b), browser [node]")
for V in ("V0", "V1", "V2"):
    node, br = runs[V]
    nn, cn = by_contract(node)
    nb, cb = by_contract(br)
    row = ", ".join(f"{k} n={nb[k]}: {cb[(k, 'a')]}/{cb[(k, 'b')]} [{cn[(k, 'a')]}/{cn[(k, 'b')]}]" for k in sorted(nb))
    print(f"{V}: {row}")

print("\n== verdict diff, browser vs node (per tx, per input, per step)")
for V in ("V0", "V1", "V2"):
    node, br = runs[V]
    nt = [r["txId"] for r in node["results"]]
    bt = [r["txId"] for r in br["results"]]
    print(f"{V}: tx lists identical and same order: {nt == bt} ({len(bt)} txs)")
    check(f"{V} browser and node results cover the same txs in the same order", nt == bt and len(bt) > 0, len(bt))
    nmap = {r["txId"]: r for r in node["results"]}
    vd = []
    ed = []
    n_cells = 0
    for r in br["results"]:
        a, b = verdicts(r), verdicts(nmap[r["txId"]])
        keys = sorted(set(a) | set(b))
        n_cells += len(keys)
        for k in keys:
            if a.get(k) != b.get(k):
                vd.append((r["txId"], k, a.get(k), b.get(k)))
        ea, eb = errors(r), errors(nmap[r["txId"]])
        for k in sorted(set(ea) | set(eb)):
            if ea.get(k) != eb.get(k):
                ed.append((r["txId"], k, ea.get(k), eb.get(k)))
    print(f"{V}: verdict cells compared {n_cells}; differing: {len(vd)}; txs with a verdict diff: {len(set(x[0] for x in vd))}")
    check(f"{V} browser verdicts = node verdicts", n_cells > 0 and not vd, f"{len(vd)} of {n_cells} cells differ")
    for x in vd[:20]:
        print(f"   VERDICT DIFF {x[0][:16]} {x[1]}: browser={x[2]} node={x[3]}")
    print(f"{V}: exact error-string differences: {len(ed)}")
    for x in ed[:10]:
        print(f"   ERR DIFF {x[0][:16]} {x[1]}:\n      browser={x[2]}\n      node   ={x[3]}")

print("\n== stack error / wasm trap / crash / console scan (browser)")
for V in ("V0", "V1", "V2"):
    _, br = runs[V]
    tot = 0
    for r in br["results"]:
        h = stack_hits(r)
        tot += len(h)
        for x in h:
            print(f"   {V} {r['txId'][:16]} {x}")
    print(f"{V}: hits {tot}")
    check(f"{V} no stack error / wasm trap / crash / console error or warning in the browser", tot == 0, f"{tot} hits")

print("\n== stack-depth probe (frames of a zero-local recursive JS function to RangeError, per page)")
for V in ("V0", "V1", "V2"):
    _, br = runs[V]
    bef = [r["browser"]["stack_probe_before"]["depth"] for r in br["results"] if r.get("browser", {}).get("stack_probe_before")]
    aft = [r["browser"]["stack_probe_after"]["depth"] for r in br["results"] if r.get("browser", {}).get("stack_probe_after")]
    errs = Counter(r["browser"]["stack_probe_after"]["err"] for r in br["results"] if r.get("browser", {}).get("stack_probe_after"))
    print(f"{V}: before n={len(bef)} min={min(bef)} max={max(bef)}; after n={len(aft)} min={min(aft)} max={max(aft)}; "
          f"errors={dict(errs)}; node reference={br['runtime']['node_stack_probe_reference']}")
    rms = [r["browser"]["run_ms"] for r in br["results"] if r.get("browser", {}).get("run_ms") is not None]
    print(f"    run_ms per tx: min={min(rms)} max={max(rms)} total={sum(rms)}")

print("\n== checks")
for name, ok, detail in CHECKS:
    print(f"{'ok  ' if ok else 'FAIL'} {name}" + (f" ({detail})" if detail else ""))
failed = [c for c in CHECKS if not c[1]]
print(f"{len(CHECKS) - len(failed)}/{len(CHECKS)} checks hold")
if JSON_OUT:
    with open(JSON_OUT, "w") as f:
        json.dump({"schema": "sigma-rust-v3-signing-browser-compare/1",
                   "checks": [{"name": n, "ok": o, "detail": d} for n, o, d in CHECKS],
                   "counts": {V: {"node": counts(runs[V][0]), "browser": counts(runs[V][1])} for V in runs}}, f, indent=1)
sys.exit(1 if failed else 0)
