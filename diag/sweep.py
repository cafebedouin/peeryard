#!/usr/bin/env python3
"""sweep.py: which runs in a tree of kept logs look unlike the others, and why?

No labels needed. Every directory that holds Ergo node logs is a run (a log directory named ci-logs, logs or out
stands for its parent), at any depth. Each log line becomes a template (timestamp and thread dropped; ids, hashes,
addresses and numbers replaced), and every run is scored on three kinds of anomaly:
  rare template     a message seen in only a few runs (default: at most 10% of them), weighted by its rarity
  count outlier     a common message whose count in this run is far from the median (robust z of log(1+count))
  feature outlier   a features.py per-node feature far from the median (robust z)
Runs are ranked by the total. It points at what to read; it does not explain a split that is common (half the runs
failing is not an anomaly): for that, label the runs and use features.py.

  python3 diag/sweep.py <dir> [<dir> ...] [--top 10] [--rare 0.10] [--z 3.5] [--group REGEX] [--json]
  python3 diag/sweep.py <dir> ... --baseline <earlier runs> ...     # novelty: what these runs show that none before did
  add --source <node checkout | logmap index> to name the code line behind each message (diag/logmap.py)

Novelty mode is the search: every pattern it lists is a candidate to check (read the lines, keep or discard, record
which), and a checked batch can join the baseline so the next sweep only shows what is new again.

Standard library only.
"""
import argparse
import math
import os
import re
import sys
from collections import Counter, defaultdict
from typing import Dict, List, Tuple

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import features as F  # noqa: E402
import logmap as LM  # noqa: E402

LOG_DIR_NAMES = {"ci-logs", "logs", "out"}
PREFIX = re.compile(r"^\d\d:\d\d:\d\d\.\d{3} +([A-Z]+) +\[[^\]]*\] +")
NORMALIZE = [
    (re.compile(r"\b[0-9a-f]{16,}\b"), "<h>"),                       # ids, hashes
    (re.compile(r"@[0-9a-f]{4,}\b"), "@<o>"),                        # object identities
    (re.compile(r"\b\d{1,3}(?:\.\d{1,3}){3}(?::\d+)?\b"), "<ip>"),   # addresses
    (re.compile(r"\b[0-9a-fA-F]{8}-[0-9a-fA-F-]{27}\b"), "<uuid>"),
    (re.compile(r"([Tt]hread)-[A-Za-z0-9]+"), r"\1-<w>"),           # generated thread names
    (re.compile(r"-?\b\d+(?:\.\d+)?\b"), "<n>"),                      # numbers
]


def template(line: str):
    """(level, template) for an Ergo log line, None for anything else."""
    m = PREFIX.match(line)
    if not m:
        return None
    text = line[m.end():].rstrip()
    for rx, sub in NORMALIZE:
        text = rx.sub(sub, text)
    return m.group(1), text[:240]


def find_runs(roots: List[str]) -> Dict[str, List[str]]:
    runs: Dict[str, List[str]] = defaultdict(list)
    for root in roots:
        for d, _, files in os.walk(root, followlinks=True):
            logs = [os.path.join(d, f) for f in files if F.node_name(f) and re.search(r"\.log(\.gz)?$", f)]
            if logs:
                run = os.path.dirname(d) if os.path.basename(d) in LOG_DIR_NAMES else d
                runs[run].extend(logs)
    return dict(runs)


def run_templates(logs: List[str], bigrams: set = None) -> Tuple[Counter, Dict[str, str]]:
    """Template counts over a run's logs; with `bigrams`, also collect (previous, next) template pairs per log."""
    counts: Counter = Counter()
    example: Dict[str, str] = {}
    for p in logs:
        prev = None
        with F._open(p) as f:
            for line in f:
                t = template(line)
                if t is None:
                    continue
                key = f"{t[0]} {t[1]}"
                counts[key] += 1
                if key not in example:
                    example[key] = line.rstrip()[:300]
                if bigrams is not None and prev is not None and prev != key:
                    bigrams.add((prev, key))
                prev = key
    return counts, example


def baseline(dirs: List[str]) -> dict:
    """What is already known: templates, template transitions, co-occurring template pairs, feature ranges."""
    runs = find_runs(dirs)
    known = {"runs": len(runs), "templates": set(), "bigrams": set(), "pairs": set(), "ranges": {}}
    for r, logs in runs.items():
        counts, _ = run_templates(logs, known["bigrams"])
        ts = sorted(counts)
        known["templates"].update(ts)
        known["pairs"].update((x, y) for i, x in enumerate(ts) for y in ts[i + 1:])
        for k, v in _features_of(logs).items():
            lo, hi = known["ranges"].get(k, (v, v))
            known["ranges"][k] = (min(lo, v), max(hi, v))
    return known


def novelty(runs: Dict[str, List[str]], known: dict, lm=None) -> List[dict]:
    """Per run: what it shows that the baseline never did. Findings are grouped across runs by pattern."""
    seen: Dict[Tuple[str, str], List[str]] = defaultdict(list)
    example: Dict[Tuple[str, str], str] = {}
    for r, logs in sorted(runs.items()):
        bg: set = set()
        counts, ex = run_templates(logs, bg)
        ts = sorted(counts)
        for t in ts:
            if t not in known["templates"]:
                seen[("new message", t)].append(r)
                example.setdefault(("new message", t), ex[t])
        for x, y in bg:
            if x in known["templates"] and y in known["templates"] and (x, y) not in known["bigrams"]:
                seen[("new transition", f"{x[:90]}  ->  {y[:90]}")].append(r)
        common = [t for t in ts if t in known["templates"] and not t.startswith("INFO")]
        for i, x in enumerate(common):
            for y in common[i + 1:]:
                if (x, y) not in known["pairs"]:
                    seen[("new co-occurrence", f"{x[:90]}  +  {y[:90]}")].append(r)
        for k, v in _features_of(logs).items():
            if k in known["ranges"]:
                lo, hi = known["ranges"][k]
                if v < lo or v > hi:
                    seen[("outside known range", f"{k} (known {lo:g}..{hi:g})")].append(r)
    out = [{"kind": kind, "pattern": pat, "runs": len(rs), "in": rs, "example": example.get((kind, pat), ""),
            "site": lm.site(example[(kind, pat)]) if lm and (kind, pat) in example else None}
           for (kind, pat), rs in seen.items()]
    order = {"new message": 0, "new co-occurrence": 1, "outside known range": 2, "new transition": 3}
    out.sort(key=lambda x: (order[x["kind"]], not x["pattern"].startswith(("ERROR", "WARN")), -x["runs"]))
    return out


def robust_z(values: List[float], rare_cut: int) -> List[float]:
    """(x - median) / (1.4826 * MAD). When MAD is 0 (most runs share one value), a value off the median gets +-inf
    only if few runs (at most rare_cut) are off it; otherwise the spread is ordinary and every z is 0."""
    s = sorted(values)
    med = s[len(s) // 2] if len(s) % 2 else (s[len(s) // 2 - 1] + s[len(s) // 2]) / 2
    dev = sorted(abs(v - med) for v in values)
    mad = dev[len(dev) // 2] if len(dev) % 2 else (dev[len(dev) // 2 - 1] + dev[len(dev) // 2]) / 2
    if mad == 0:
        off = sum(1 for v in values if v != med)
        if off > rare_cut:
            return [0.0] * len(values)
        return [0.0 if v == med else math.copysign(math.inf, v - med) for v in values]
    return [(v - med) / (1.4826 * mad) for v in values]


def sweep(runs: Dict[str, List[str]], rare_frac: float, zmax: float, lm=None) -> Tuple[List[dict], List[dict]]:
    names = sorted(runs)
    n = len(names)
    tcounts, examples, feats = {}, {}, {}
    for r in names:
        tcounts[r], ex = run_templates(runs[r])
        for k, v in ex.items():
            examples.setdefault(k, (r, v))
        feats[r] = _features_of(runs[r])
    df = Counter(k for r in names for k in tcounts[r])
    rare_cut = max(1, math.floor(rare_frac * n))
    flags: Dict[str, List[Tuple[float, str]]] = {r: [] for r in names}

    # Every signal is keyed by the exact set of runs it fires in; signals with the same set are one finding
    # (a hung run missing two containers shows up in dozens of startup templates, but it is one fact).
    groups: Dict[Tuple[str, frozenset], List[Tuple[float, str]]] = defaultdict(list)
    rare = []
    for k, c in df.items():
        if c <= rare_cut and c < n:
            weight = math.log(n / c) * (2 if k.startswith(("ERROR", "WARN")) else 1)
            present = [r for r in names if k in tcounts[r]]
            site = lm.site(examples[k][1]) if lm else None
            rare.append({"template": k, "runs": c, "weight": round(weight, 2), "in": present,
                         "example": examples[k][1], "site": site})
            groups[("rare", frozenset(present))].append(
                (weight, f"rare ({c}/{n}): {k[:120]}" + (f"  <- {site}" if site else "")))

    for k, c in df.items():
        if c < n / 2:
            continue
        vals = [math.log1p(tcounts[r].get(k, 0)) for r in names]
        zs = robust_z(vals, rare_cut)
        hit = frozenset(r for r, z in zip(names, zs) if abs(z) >= zmax)
        if hit and len(hit) <= rare_cut:
            z = next(z for r, z in zip(names, zs) if r in hit)
            groups[("count", hit)].append((1.0, f"count z={_fmt(z)}: {k[:100]}"))

    keys = sorted({k for r in names for k in feats[r]})
    for k in keys:
        present = [r for r in names if k in feats[r]]
        if len(present) < max(5, n // 2):
            continue
        zs = robust_z([feats[r][k] for r in present], rare_cut)
        hit = {r: z for r, z in zip(present, zs) if abs(z) >= zmax}
        if hit and len(hit) <= rare_cut:
            for r, z in hit.items():
                groups[("feature", frozenset([r]))].append((2.0, f"feature {k}={feats[r][k]:g} z={_fmt(z)}"))

    for (kind, members), items in groups.items():
        items.sort(reverse=True)
        weight = items[0][0]
        label = items[0][1] + (f"  [+{len(items) - 1} more {kind} signals on the same runs]" if len(items) > 1 else "")
        for r in members:
            flags[r].append((weight, label))

    ranked = sorted(({"run": r, "score": round(sum(w for w, _ in flags[r]), 2),
                      "flags": [t for _, t in sorted(flags[r], reverse=True)]} for r in names),
                    key=lambda x: -x["score"])
    rare.sort(key=lambda x: (x["runs"], -x["weight"]))
    return ranked, rare


def _features_of(logs: List[str]) -> Dict[str, float]:
    """features.py's per-node features over exactly these logs (containers of a node ordered by first timestamp)."""
    by_node: Dict[str, List[Tuple[int, Dict[str, float]]]] = defaultdict(list)
    for p in logs:
        first, f = F.log_features(p)
        if first is not None:
            by_node[F.node_name(p)].append((first, f))
    out = {}
    for name, entries in by_node.items():
        entries.sort(key=lambda e: e[0])
        out[f"{name}.containers"] = len(entries)   # structural: a restart that never happened, or one extra
        for i, (_, f) in enumerate(entries, 1):
            out.update({f"{name}#{i}.{k}": v for k, v in f.items()})
    return out


def _fmt(z: float) -> str:
    return ("+inf" if z > 0 else "-inf") if math.isinf(z) else f"{z:+.1f}"


def main(argv: List[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("dirs", nargs="+")
    ap.add_argument("--top", type=int, default=10)
    ap.add_argument("--rare", type=float, default=0.10, help="a template in at most this fraction of runs is rare")
    ap.add_argument("--z", type=float, default=3.5, help="robust z threshold for count and feature outliers")
    ap.add_argument("--group", help="regex; runs whose paths give the same first match (or group 1) are swept "
                                    "together, so one fixture or stack is compared with itself")
    ap.add_argument("--baseline", nargs="+", help="dirs of earlier runs: report what the swept runs show that these "
                                                     "never did (novelty) instead of how they differ from each other")
    ap.add_argument("--source", help="node source checkout (or a logmap.py index): name the code line behind each message")
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args(argv)
    a.lm = LM.LogMap(LM.load(a.source)) if a.source else None
    runs = find_runs(a.dirs)
    if a.baseline:
        known = baseline(a.baseline)
        found = novelty(runs, known, a.lm)
        if a.json:
            import json
            print(json.dumps({"baseline_runs": known["runs"], "runs": len(runs), "novel": found}, indent=1))
            return 0
        print(f"{len(runs)} runs against a baseline of {known['runs']} runs: {len(found)} novel patterns")
        kinds = Counter(x["kind"] for x in found)
        print("  " + ", ".join(f"{v} {k}" for k, v in kinds.items()))
        shown = Counter()
        for x in found:
            if shown[x["kind"]] >= a.top:
                continue
            shown[x["kind"]] += 1
            print(f"\n[{x['kind']}] in {x['runs']}/{len(runs)} runs: {x['pattern'][:200]}")
            if x["example"]:
                print(f"    e.g. {x['example'][:200]}")
            if x.get("site"):
                print(f"    at {x['site']}")
        return 0
    groups: Dict[str, Dict[str, List[str]]] = defaultdict(dict)
    for r, logs in runs.items():
        m = re.search(a.group, r) if a.group else None
        key = (m.group(1) if m and m.groups() else m.group(0) if m else "") or "(no match)"
        groups[key if a.group else "all"][r] = logs
    status = 0
    for g in sorted(groups):
        if a.group:
            print(f"=== group {g}")
        status = max(status, _report(groups[g], a))
    return status


def _report(runs: Dict[str, List[str]], a) -> int:
    if len(runs) < 5:
        print(f"sweep.py: found {len(runs)} runs; need at least 5 to call anything unusual", file=sys.stderr)
        return 2
    ranked, rare = sweep(runs, a.rare, a.z, a.lm)
    if a.json:
        import json
        print(json.dumps({"runs": len(runs), "ranked": ranked[:a.top], "rare_templates": rare[:a.top * 3]}, indent=1))
        return 0
    print(f"{len(runs)} runs")
    for x in ranked[:a.top]:
        print(f"\n{x['score']:7.2f}  {x['run']}")
        for t in x["flags"][:6]:
            print(f"         {t}")
        if len(x["flags"]) > 6:
            print(f"         ... {len(x['flags']) - 6} more")
    print(f"\nrarest templates (of {sum(1 for _ in rare)}):")
    for r in rare[:a.top]:
        print(f"  {r['runs']}/{len(runs)} runs  {r['template'][:110]}" + (f"\n      at {r['site']}" if r.get("site") else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
