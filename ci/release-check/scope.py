#!/usr/bin/env python3
"""scope.py: what a release candidate changes since the baseline release, and which release-check scenarios to run.

  python3 ci/release-check/scope.py --clone <ergo clone> --baseline <tag> --candidate <commit> [--candidate-ref <name>]
                                    [--api] [--out DIR]

Lists the commits in <baseline>..<candidate> (git log, every commit, merges included), the pull requests they came
from, and the paths whose content differs between the two trees. Each path is mapped to scenarios by
ci/release-check/path-map.tsv (every matching row applies); the selection is the union of those scenarios plus the
catalog's core set (ci/release-check/catalog.tsv, core = 1), in catalog order.

Pull requests: the "(#N)" and "Merge pull request #N" references in commit subjects. With --api, a commit whose subject
names none is looked up with `gh api repos/<repo>/commits/<sha>/pulls` (the merged pull requests that contain it), and
every pull request's title is read with `gh api repos/<repo>/pulls/<N>`; without --api the titles are left empty and
such commits are listed with no pull request. Read-only: nothing is written outside DIR.

Writes DIR/scope.json and DIR/scope.md (default DIR: .). Standard library only, plus git (and gh with --api)."""
import argparse, json, os, re, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = "ergoplatform/ergo"
PR_RE = re.compile(r"\(#(\d+)\)|Merge pull request #(\d+)")


def git(clone, *args):
    return subprocess.run(["git", "-C", clone, *args], check=True, capture_output=True, text=True).stdout


def gh_json(path):
    r = subprocess.run(["gh", "api", path], capture_output=True, text=True)
    if r.returncode != 0:
        return None
    try:
        return json.loads(r.stdout)
    except json.JSONDecodeError:
        return None


def read_tsv(path, ncols):
    rows = []
    with open(path) as f:
        for line in f:
            line = line.rstrip("\n")
            if not line or line.startswith("#"):
                continue
            cols = line.split("\t")
            if len(cols) != ncols:
                sys.exit(f"scope: {path}: expected {ncols} tab-separated columns, got {len(cols)}: {line[:80]}")
            rows.append(cols)
    return rows


def load_catalog(path):
    out = []
    for name, part, core, base_arm, rate, covers in read_tsv(path, 6):
        if part not in ("suite", "upgrade", "rates"):
            sys.exit(f"scope: catalog: {name}: part must be suite, upgrade or rates")
        out.append({"name": name, "part": part, "core": core == "1", "baseline_arm": base_arm == "1",
                    "rate": None if rate == "-" else rate, "covers": covers})
    return out


def load_map(path, names):
    out = []
    for pat, scen, note in read_tsv(path, 3):
        s = [] if scen == "-" else scen.split()
        bad = [x for x in s if x not in names]
        if bad:
            sys.exit(f"scope: path-map: {pat}: not in the catalog: {' '.join(bad)}")
        out.append({"pattern": pat, "re": re.compile(pat), "scenarios": s, "note": note})
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--clone", required=True)
    ap.add_argument("--baseline", required=True, help="the baseline release tag")
    ap.add_argument("--candidate", required=True, help="the candidate commit (or any ref the clone resolves)")
    ap.add_argument("--candidate-ref", default="", help="the name the candidate was given (branch or tag), for the report")
    ap.add_argument("--catalog", default=os.path.join(HERE, "catalog.tsv"))
    ap.add_argument("--map", default=os.path.join(HERE, "path-map.tsv"))
    ap.add_argument("--api", action="store_true", help="look up pull requests and titles with gh api")
    ap.add_argument("--out", default=".")
    a = ap.parse_args()

    catalog = load_catalog(a.catalog)
    names = [c["name"] for c in catalog]
    pmap = load_map(a.map, set(names))
    bsha = git(a.clone, "rev-parse", "--verify", f"{a.baseline}^{{commit}}").strip()
    csha = git(a.clone, "rev-parse", "--verify", f"{a.candidate}^{{commit}}").strip()
    ancestor = subprocess.run(["git", "-C", a.clone, "merge-base", "--is-ancestor", bsha, csha]).returncode == 0
    mb = git(a.clone, "merge-base", bsha, csha).strip()

    commits, prs = [], {}
    log = git(a.clone, "log", "--format=%H%x09%P%x09%s", f"{bsha}..{csha}")
    for line in log.splitlines():
        sha, parents, subject = line.split("\t", 2)
        refs = sorted({int(x or y) for x, y in PR_RE.findall(subject)})
        source = "subject" if refs else ""
        if not refs and a.api:
            got = gh_json(f"repos/{REPO}/commits/{sha}/pulls")
            if isinstance(got, list):
                refs = sorted({p["number"] for p in got if p.get("merged_at")})
                source = "api" if refs else ""
        commits.append({"sha": sha, "parents": parents.split(), "merge": len(parents.split()) > 1, "subject": subject,
                        "prs": refs, "pr_source": source})
        for n in refs:
            prs.setdefault(n, {"number": n, "title": "", "commits": 0})
            prs[n]["commits"] += 1
    # a merge commit that names a pull request brings in that pull request's commits (its second parent's side)
    by_sha = {c["sha"]: c for c in commits}
    for m in commits:
        if m["merge"] and m["prs"] and len(m["parents"]) == 2:
            for sha in git(a.clone, "rev-list", f"{m['parents'][0]}..{m['parents'][1]}").split():
                c = by_sha.get(sha)
                if c is not None and not c["prs"]:
                    c["prs"], c["pr_source"] = list(m["prs"]), "merge"
                    for n in m["prs"]:
                        prs[n]["commits"] += 1
    if a.api:
        for n, p in prs.items():
            got = gh_json(f"repos/{REPO}/pulls/{n}")
            if isinstance(got, dict):
                p["title"] = got.get("title", "")
                p["base"] = (got.get("base") or {}).get("ref", "")

    paths = []
    for p in git(a.clone, "diff", "--name-only", bsha, csha).splitlines():
        hit = [r for r in pmap if r["re"].search(p)]
        scen = sorted({s for r in hit for s in r["scenarios"]}, key=names.index)
        paths.append({"path": p, "scenarios": scen, "rows": [r["pattern"] for r in hit],
                      "notes": [r["note"] for r in hit], "mapped": bool(hit)})

    chosen = {s for p in paths for s in p["scenarios"]}
    selected = [c["name"] for c in catalog if c["core"] or c["name"] in chosen]
    why = {c["name"]: ("core" if c["core"] else "") for c in catalog}
    for p in paths:
        for s in p["scenarios"]:
            if not why[s]:
                why[s] = "path"
    scope = {
        "schema_version": 1, "repo": REPO,
        "baseline": {"tag": a.baseline, "sha": bsha},
        "candidate": {"ref": a.candidate_ref or a.candidate, "sha": csha},
        "baseline_is_ancestor": ancestor, "merge_base": mb,
        "commits": commits, "prs": sorted(prs.values(), key=lambda p: p["number"]),
        "paths": paths, "unmapped": [p["path"] for p in paths if not p["mapped"]],
        "selected": selected, "selected_by": {s: why[s] for s in selected},
        "catalog": catalog,
    }
    os.makedirs(a.out, exist_ok=True)
    with open(os.path.join(a.out, "scope.json"), "w") as f:
        json.dump(scope, f, indent=1)
        f.write("\n")
    with open(os.path.join(a.out, "scope.md"), "w") as f:
        f.write(render(scope))
    print(f"scope: {len(commits)} commits, {len(prs)} pull requests, {len(paths)} paths "
          f"({len(scope['unmapped'])} unmapped); selected: {' '.join(selected)}")


def render(s):
    b, c = s["baseline"], s["candidate"]
    out = [f"### Scope: {c['ref']} (`{c['sha'][:12]}`) since {b['tag']} (`{b['sha'][:12]}`)", ""]
    if not s["baseline_is_ancestor"]:
        out += [f"The baseline is not an ancestor of the candidate; the commits are {b['tag']}..candidate "
                f"(merge base `{s['merge_base'][:12]}`).", ""]
    n_merge = sum(1 for x in s["commits"] if x["merge"])
    out += [f"{len(s['commits'])} commits ({n_merge} merges), {len(s['prs'])} pull requests, {len(s['paths'])} changed paths.", ""]
    if s["prs"]:
        out += ["| PR | title | commits |", "|---|---|---|"]
        for p in s["prs"]:
            t = p["title"].replace("|", "\\|") or "(title not read)"
            out.append(f"| [#{p['number']}](https://github.com/{s['repo']}/pull/{p['number']}) | {t} | {p['commits']} |")
        out.append("")
    loose = [x for x in s["commits"] if not x["prs"] and not x["merge"]]
    if loose:
        out += ["Commits with no pull request found:", ""]
        out += [f"- `{x['sha'][:9]}` {x['subject']}" for x in loose]
        out.append("")
    out += ["| changed path | scenarios | note |", "|---|---|---|"]
    for p in s["paths"]:
        sc = " ".join(p["scenarios"]) or ("-" if p["mapped"] else "**unmapped**")
        out.append(f"| `{p['path']}` | {sc} | {'; '.join(p['notes'])} |")
    out += ["", "Selected: " + ", ".join(f"{n} ({s['selected_by'][n]})" for n in s["selected"]), ""]
    return "\n".join(out)


if __name__ == "__main__":
    main()
