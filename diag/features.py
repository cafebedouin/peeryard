#!/usr/bin/env python3
"""features.py: which per-run feature separates the runs that failed from the runs that passed?

Kept logs usually hold the answer to "why did 4 of 8 fail?", but finding it by hand means reading every log. This
tool extracts the same features from every Ergo node log of every run (chain-switch steps, the header lead over full
blocks, wallet rescans, miner start, download retries, errors), then ranks each feature by how well it separates the
runs' outcomes: first the features whose two outcome groups do not overlap at all (with the widest gap), then by the
area under the ROC curve. It names candidates; it does not prove a cause. Confirm the top feature by forcing that
state in a test: network runs discover, forced-state tests prove.

  python3 diag/features.py --labels labels.tsv [--top 10] [--json]
  python3 diag/features.py --runs 'out/*/' [--top 10]          # outcome from each run's "(verdict: X)" line

labels.tsv: one run per line, "<run dir><TAB><outcome>". A run dir holds node logs anywhere below it (*.log or
*.log.gz, with an Ergo timestamp at the start of each line). A node is named by its file: "node_C.log" -> C,
"...-node10-<container>.log" -> node10; when a node has several logs (one container per restart), they are ordered
by their first timestamp and keyed node10#1, node10#2, ... (a single log is #1). Features are keyed
"<node>#<n>.<feature>".

Standard library only.
"""
import argparse
import glob
import gzip
import json
import os
import re
import sys
from typing import Dict, List, Optional, Tuple

TS = re.compile(r"^(\d\d):(\d\d):(\d\d)\.(\d{3}) ")
BEST_HEADER = re.compile(r"New best header \S+ with score \d+\. New height (\d+)")
FULL_UTXO = re.compile(r"applied to UtxoState at height (\d+)")
FULL_BEST = re.compile(r"New best block is \S+ with height (\d+)")
SWITCH = re.compile(r"going to apply (\d+) and to remove (\d+)")
WALLET_SKIPPED = re.compile(r"skipped blocks found starting from")
MINER_START = re.compile(r"Blockchain is \(almost\) synced .* starting mining")
MINER_WAIT = re.compile(r"Blockchain not synced yet")
RESCHEDULE = re.compile(r"Rescheduling request for")
NO_PEERS_DL = re.compile(r"No peers available in requestDownload")
ROLLBACK = re.compile(r"Rollback UtxoState to version")
LEVEL_ERROR = re.compile(r"^\S+ ERROR ")
VERDICT = re.compile(r"\(verdict: ([A-Z_]+)\)")
# One representative log line per extracted feature: with --source, logmap.py names the code that writes it.
FEATURE_SOURCE = {
    "final_header_height": "00:00:00.000 INFO  [x] o.e.n.h.ErgoHistory$$anon$1 - New best header x with score 1. New height 1, old height 0",
    "final_full_height": "00:00:00.000 INFO  [x] o.e.n.state.UtxoState - Valid modifier with header x and emission box None applied to UtxoState at height 1",
    "first_switch_apply": "00:00:00.000 INFO  [x] o.e.n.h.ErgoHistory$$anon$1 - Full block x appended, going to apply 1 and to remove 1 modifiers.",
    "wallet_skipped": "00:00:00.000 WARN  [x] o.e.n.w.ErgoWalletActor - Wallet: skipped blocks found starting from 1, going back to scan them",
    "miner_started": "00:00:00.000 INFO  [x] o.e.mining.ErgoMiner - Blockchain is (almost) synced (headers: 1, full blocks: 1), starting mining",
    "miner_wait": "00:00:00.000 INFO  [x] o.e.mining.ErgoMiner - Blockchain not synced yet (headers: 1, full blocks: 1), waiting for sync",
    "reschedule": "00:00:00.000 INFO  [x] o.e.n.ErgoNodeViewSynchronizer - Rescheduling request for x , new peer y",
    "no_peers_download": "00:00:00.000 WARN  [x] o.e.n.ErgoNodeViewSynchronizer - No peers available in requestDownload",
    "rollback": "00:00:00.000 INFO  [x] o.e.n.state.UtxoState - Rollback UtxoState to version x",
}
FEATURE_SOURCE.update({k: FEATURE_SOURCE["first_switch_apply"] for k in
                       ("first_switch_remove", "first_switch_lead", "max_switch_remove", "switches")})
FEATURE_SOURCE.update({k: FEATURE_SOURCE["final_header_height"] for k in ("final_lead", "max_lead")})
NODE_UNDERSCORE = re.compile(r"node_([A-Za-z0-9]+)\.log")
NODE_DASH = re.compile(r"-(node\d+)-[0-9a-f]+\.log")


def _open(path: str):
    return gzip.open(path, "rt", errors="replace") if path.endswith(".gz") else open(path, errors="replace")


def node_name(path: str) -> Optional[str]:
    base = os.path.basename(path)
    m = NODE_UNDERSCORE.search(base) or NODE_DASH.search(base)
    return m.group(1) if m else None


def log_features(path: str) -> Tuple[Optional[int], Dict[str, float]]:
    """(first timestamp in ms of the day, features) for one node log; None when it holds no Ergo log line."""
    first = None
    header = full = 0
    max_lead = 0
    switches: List[Tuple[int, int, int]] = []   # (apply, remove, header lead just before the switch)
    counts = {"wallet_skipped": 0, "miner_wait": 0, "reschedule": 0, "no_peers_download": 0, "rollback": 0,
              "errors": 0}
    miner_started = 0
    with _open(path) as f:
        for line in f:
            m = TS.match(line)
            if not m:
                continue
            if first is None:
                h, mi, s, ms = (int(x) for x in m.groups())
                first = ((h * 60 + mi) * 60 + s) * 1000 + ms
            if LEVEL_ERROR.match(line):
                counts["errors"] += 1
            m = BEST_HEADER.search(line)
            if m:
                header = int(m.group(1))
            m = SWITCH.search(line)   # before this line's own full-height update: the lead going into the switch
            if m:
                switches.append((int(m.group(1)), int(m.group(2)), max(0, header - full)))
            m = FULL_UTXO.search(line) or FULL_BEST.search(line)
            if m:
                full = int(m.group(1))  # the last value seen: a rollback lowers it
            if header and full:
                max_lead = max(max_lead, header - full)
            if WALLET_SKIPPED.search(line):
                counts["wallet_skipped"] += 1
            if MINER_START.search(line):
                miner_started = 1
            if MINER_WAIT.search(line):
                counts["miner_wait"] += 1
            if RESCHEDULE.search(line):
                counts["reschedule"] += 1
            if NO_PEERS_DL.search(line):
                counts["no_peers_download"] += 1
            if ROLLBACK.search(line):
                counts["rollback"] += 1
    if first is None:
        return None, {}
    feats: Dict[str, float] = {
        "final_header_height": header, "final_full_height": full, "final_lead": max(0, header - full),
        "max_lead": max_lead, "switches": len(switches), "miner_started": miner_started,
    }
    feats.update(counts)
    if switches:
        feats["first_switch_apply"] = switches[0][0]
        feats["first_switch_remove"] = switches[0][1]
        feats["first_switch_lead"] = switches[0][2]
        feats["max_switch_remove"] = max(r for _, r, _ in switches)
    return first, feats


def run_features(run_dir: str) -> Dict[str, float]:
    logs: Dict[str, List[Tuple[int, Dict[str, float]]]] = {}
    paths = sorted(set(glob.glob(os.path.join(run_dir, "**", "*.log"), recursive=True)
                       + glob.glob(os.path.join(run_dir, "**", "*.log.gz"), recursive=True)))
    for p in paths:
        name = node_name(p)
        if name is None:
            continue
        first, feats = log_features(p)
        if first is not None:
            logs.setdefault(name, []).append((first, feats))
    out: Dict[str, float] = {}
    for name, entries in logs.items():
        entries.sort(key=lambda e: e[0])
        for i, (_, feats) in enumerate(entries, 1):
            key = f"{name}#{i}"   # always numbered, so runs with one container and runs with two share keys
            for k, v in feats.items():
                out[f"{key}.{k}"] = v
    return out


def run_verdict(run_dir: str) -> Optional[str]:
    """The last "(verdict: X)" in any non-node *.txt / *.log directly in or below the run dir."""
    found = None
    for p in sorted(glob.glob(os.path.join(run_dir, "**", "*"), recursive=True)):
        if not os.path.isfile(p) or node_name(p) or not re.search(r"\.(txt|log)(\.gz)?$", p):
            continue
        with _open(p) as f:
            for line in f:
                m = VERDICT.search(line)
                if m:
                    found = m.group(1)
    return found


def auc(pos: List[float], neg: List[float]) -> float:
    """P(a random positive value > a random negative value), ties counted half."""
    wins = sum((p > n) + 0.5 * (p == n) for p in pos for n in neg)
    return wins / (len(pos) * len(neg))


def rank(rows: Dict[str, Dict[str, float]], labels: Dict[str, str], target: str) -> List[dict]:
    """Rank features by how well they separate runs labelled `target` from the rest."""
    keys = sorted({k for r in rows.values() for k in r})
    out = []
    for k in keys:
        pos = [rows[r][k] for r in rows if labels[r] == target and k in rows[r]]
        neg = [rows[r][k] for r in rows if labels[r] != target and k in rows[r]]
        missing = sum(1 for r in rows if k not in rows[r])
        if not pos or not neg:
            continue
        a = auc(pos, neg)
        direction = "higher" if a >= 0.5 else "lower"
        a2 = max(a, 1 - a)
        if direction == "higher":
            gap = min(pos) - max(neg)
        else:
            gap = min(neg) - max(pos)
        out.append({"feature": k, "separates": gap > 0, "gap": gap, "auc": round(a2, 3), "direction": direction,
                    "target_range": [min(pos), max(pos)], "other_range": [min(neg), max(neg)],
                    "n_target": len(pos), "n_other": len(neg), "missing_in": missing})
    out.sort(key=lambda r: (not r["separates"], r["missing_in"] > 0, -r["auc"], -r["gap"]))
    return out


def main(argv: List[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--labels", help="TSV: run dir <TAB> outcome")
    ap.add_argument("--runs", help="glob of run dirs; outcome from their '(verdict: X)' line")
    ap.add_argument("--target", help="the outcome to explain (default: the rarer one)")
    ap.add_argument("--top", type=int, default=10)
    ap.add_argument("--source", help="node source checkout (or a logmap.py index): name the code behind each feature")
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args(argv)
    lm = None
    if a.source:
        import logmap
        lm = logmap.LogMap(logmap.load(a.source))
    labels: Dict[str, str] = {}
    if a.labels:
        with open(a.labels) as f:
            for line in f:
                if line.strip() and not line.startswith("#"):
                    d, lab = line.rstrip("\n").split("\t")[:2]
                    labels[d] = lab
    elif a.runs:
        for d in sorted(glob.glob(a.runs)):
            v = run_verdict(d)
            if v:
                labels[d] = v
    else:
        ap.error("give --labels or --runs")
    if len(set(labels.values())) < 2:
        print("features.py: need runs with at least two different outcomes", file=sys.stderr)
        return 2
    rows = {d: run_features(d) for d in labels}
    counts: Dict[str, int] = {}
    for lab in labels.values():
        counts[lab] = counts.get(lab, 0) + 1
    target = a.target or min(counts, key=lambda k: counts[k])
    ranked = rank(rows, labels, target)
    if lm:
        for r in ranked:
            src = FEATURE_SOURCE.get(r["feature"].split(".", 1)[-1])
            r["site"] = lm.site(src) if src else None
    if a.json:
        print(json.dumps({"target": target, "counts": counts, "features": ranked[:a.top]}, indent=1))
        return 0
    print(f"target: {target} ({counts[target]} runs) vs the rest ({sum(counts.values()) - counts[target]} runs)")
    print(f"{'feature':38} {'sep':4} {'auc':>5} {'gap':>6}  {target + ' range':>14}  {'other range':>12}  missing")
    for r in ranked[:a.top]:
        tr = "{:g}-{:g}".format(*r["target_range"])
        orng = "{:g}-{:g}".format(*r["other_range"])
        print(f"{r['feature']:38} {'YES' if r['separates'] else '':4} {r['auc']:5.2f} {r['gap']:6g}  {tr:>14}  "
              f"{orng:>12}  {r['missing_in'] or ''}")
        if r.get("site"):
            print(f"{'':44}from {r['site']}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
