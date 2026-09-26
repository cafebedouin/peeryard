#!/usr/bin/env python3
"""stack_order.py: how much of each open PR's changed surface is duplicated in another open PR, and which
merge would shrink the other PRs' diffs most.

  stack_order.py --repo <clone> --base <ref-or-sha> --prs 2501 2505 ... [--pr-ref 'refs/pull/{n}'] [--roots] [--json out.json]

Git only; the clone needs the PR heads as local refs, e.g.
  git fetch origin '+refs/pull/<n>/head:refs/pull/<n>'   (then --pr-ref 'refs/pull/{n}', the default)

  surface(Y)        added + deleted lines in the diff from Y's merge base with the base branch, per `git
                    numstat` (binary files skipped). When there are several merge bases (criss-cross master
                    merges), the tool uses the one giving the smallest diff — a stable, reviewer-oriented
                    comparison (in the common case this is also the diff GitHub shows).
  overlap(X -> Y)   changed lines of X whose exact -U0 hunk text appears, verbatim and contiguous, inside a
                    hunk of Y in the same file. This is a heuristic: it says the same changed lines appear in
                    both diffs, not that Y authored them. It leaves Y's diff once X merges and Y rebases onto
                    it — provided Y rebases onto the same parent.
  score(X)          sum of overlap(X -> Y) over the other PRs. A debug view; --roots is the real planner.

Matching is exact-hunk containment (>= --min-hunk changed lines), which avoids counting shared one-liners but
misses near-copies that differ by a line, a renamed file, or a reformatted block — so reported overlap is a
lower bound. See "Roadmap" at the foot of this file for the deferred stronger models.
"""
import argparse, collections, json, subprocess, sys

# Deterministic diff: no config-driven rename detection, external drivers or textconv.
DET = ["--no-ext-diff", "--no-textconv", "--no-renames"]
DIFF = ["diff", "--no-color", *DET, "-U0"]

class GitError(RuntimeError):
    pass

def git(repo, *args, check=True):
    r = subprocess.run(["git", "-C", repo, *args], capture_output=True, text=True)
    if check and r.returncode != 0:
        raise GitError(f"git {' '.join(args)}: {r.stderr.strip()}")
    return r

def rev(repo, ref):
    """Resolve a commit, or None if the ref is absent (absence is expected, so it is not an error)."""
    v = git(repo, "rev-parse", "--verify", "--quiet", ref + "^{commit}", check=False).stdout.strip()
    return v or None

def _path(line):
    """Path from a '+++ '/'--- ' diff line: strip the a//b/ prefix; None for /dev/null."""
    p = line[4:]
    if p == "/dev/null":
        return None
    if p[:2] in ("a/", "b/"):
        p = p[2:]
    return p

def numstat_total(repo, a, b):
    t = 0
    for l in git(repo, "diff", "--numstat", *DET, a, b).stdout.splitlines():
        parts = l.split("\t")
        if len(parts) < 3:
            continue
        added, deleted = parts[0], parts[1]
        if added == "-" or deleted == "-":       # binary: skipped (documented in surface())
            continue
        t += int(added) + int(deleted)
    return t

def best_merge_base(repo, base, head):
    """(merge base, surface) with the smallest diff to head, or None when base and head share no history."""
    r = git(repo, "merge-base", "--all", base, head, check=False)
    if r.returncode == 1 and not r.stdout.strip():  # git's answer for unrelated histories: no merge base
        return None
    if r.returncode != 0:
        raise GitError(f"git merge-base --all {base} {head}: {r.stderr.strip()}")
    best = None
    for mb in r.stdout.split():
        n = numstat_total(repo, mb, head)
        if best is None or n < best[1]:
            best = (mb, n)
    return best

def merge_status(repo, base, head, have_write_tree, mb):
    """'clean' | 'conflict' | 'unknown' — a merge into base with the version-appropriate merge-tree.
    mb is the merge base of base and head (the one best_merge_base chose)."""
    if have_write_tree:
        return "clean" if git(repo, "merge-tree", "--write-tree", base, head, check=False).returncode == 0 else "conflict"
    # Old git: `merge-tree <merge-base> <base> <head>` prints conflict markers to stdout on conflict. The first
    # argument must be the real merge base: with base there, base's side has no changes and every merge is clean.
    r = git(repo, "merge-tree", mb, base, head, check=False)
    if r.returncode != 0:
        return "unknown"
    return "conflict" if ("<<<<<<<" in r.stdout or "changed in both" in r.stdout) else "clean"

def hunks(repo, a, b):
    """{path: [ '\\n'.join(signed lines of one hunk), ... ]} from a -U0 diff.

    The file key comes from the '+++' line, or the '---' line when '+++' is /dev/null (a deletion) — so two
    independent deletions of different files do not collapse together under /dev/null. Signed lines are kept
    exactly as git emits them (no rstrip: trailing-whitespace changes are real changes)."""
    out = collections.defaultdict(list); f = None; minus = None; cur = []
    def flush():
        if f and cur:
            out[f].append("\n".join(cur))
    for l in git(repo, *DIFF, a, b).stdout.split("\n"):
        if l.startswith("diff --git "):
            flush(); cur = []; f = None; minus = None
        elif l.startswith("--- "):
            minus = _path(l)
        elif l.startswith("+++ "):
            p = _path(l)
            f = p if p is not None else minus
        elif l.startswith("@@"):
            flush(); cur = []
        elif l and l[0] in "+-" and not l.startswith(("+++ ", "--- ")):
            cur.append(l)
    flush()
    return out

def hunklen(h):
    return h.count("\n") + 1

def overlap(hx, hy, min_hunk):
    """Changed lines of X whose exact hunk appears within a hunk of Y, same file. Source hunks are
    de-duplicated per file so a repeated identical hunk is not counted twice."""
    n = 0
    for f, xs in hx.items():
        ys = hy.get(f)
        if not ys:
            continue
        yset = set(ys)                                  # exact match: O(1)
        wrapped = ["\n" + y + "\n" for y in ys]         # containment: substring
        for x in set(xs):
            k = hunklen(x)
            if k >= min_hunk and (x in yset or any(("\n" + x + "\n") in w for w in wrapped)):
                n += k
    return n

def root_analysis(H, min_hunk):
    """Credit each duplicated block to one candidate-root PR and rank the carrier-first candidates.

    owners[(file,hunk)] = the set of PRs whose diff contains that exact hunk (>= min_hunk lines). A hunk in
    >= 2 PRs is duplicated; hunks with the same owner-set share an attribution group (NOT necessarily one
    contiguous block). save(group) = lines * (owners - 1): the review lines removed from the other owners
    once the block lands once and they rebase onto it. The candidate root is the owner PR carrying the least
    OTHER baggage (smallest surface once this block is removed) — the cleanest first merge; None means no
    single PR holds the whole group, so it should be extracted into its own PR.

    KNOWN LIMITATION: a group is keyed by its exact owner-set, so every owner holds every
    hunk by construction -> holders == owners, root is never None, and the "extract" branch cannot fire.
    'root' is therefore only the smallest/least-baggage CARRIER, not provenance or dependency (semantic
    ownership and ancestry are invisible from hunks). Treat as triage, not merge-order authority. Real fix:
    the measured-residual mode in the Roadmap (synthetically land X, rebase each Y, recompute the residual)."""
    owners = collections.defaultdict(set)
    hlen = {}
    for n, hs in H.items():
        for f, lst in hs.items():
            for h in lst:
                k = hunklen(h)
                if k >= min_hunk:
                    owners[(f, h)].add(n); hlen[(f, h)] = k
    pr_hunks = {n: {(f, h) for f, lst in H[n].items() for h in lst if hunklen(h) >= min_hunk} for n in H}
    pr_lines = {n: sum(hlen[k] for k in pr_hunks[n]) for n in H}
    groups = collections.defaultdict(lambda: {"lines": 0, "hunks": 0, "files": set(), "keys": []})
    for key, own in owners.items():
        if len(own) >= 2:
            g = groups[frozenset(own)]
            g["lines"] += hlen[key]; g["hunks"] += 1; g["files"].add(key[0].split("/")[-1]); g["keys"].append(key)
    out = []
    for own, g in groups.items():
        gset = set(g["keys"])
        holders = [p for p in own if gset <= pr_hunks[p]]           # PRs that hold the whole group
        root = min(holders, key=lambda p: pr_lines[p] - g["lines"]) if holders else None
        out.append({"owners": sorted(own), "lines": g["lines"], "hunks": g["hunks"],
                    "files": sorted(g["files"]), "save": g["lines"] * (len(own) - 1), "root": root})
    out.sort(key=lambda x: -x["save"])
    per_pr = {n: {"own": pr_lines[n] - sum(hlen[k] for k in pr_hunks[n] if len(owners[k]) > 1),
                  "shared": sum(hlen[k] for k in pr_hunks[n] if len(owners[k]) > 1)} for n in H}
    return {"groups": out, "per_pr": per_pr}

def write_json(res, path):
    with open(path, "w", encoding="utf-8") as f:
        json.dump(res, f, indent=1, default=str)
        f.write("\n")

def main():
    ap = argparse.ArgumentParser(description="Rank which landing shrinks the most cross-PR review.")
    ap.add_argument("--repo", required=True)
    ap.add_argument("--base", required=True, help="base branch ref the PRs target")
    ap.add_argument("--prs", nargs="+", type=int, required=True)
    ap.add_argument("--pr-ref", default="refs/pull/{n}", help="local ref pattern per PR head (default refs/pull/{n})")
    ap.add_argument("--min-hunk", type=int, default=2)
    ap.add_argument("--roots", action="store_true", help="report carrier/landing-order roots (the planner)")
    ap.add_argument("--top", type=int, default=20, help="rows to print")
    ap.add_argument("--json")
    a = ap.parse_args()
    if a.min_hunk < 1:
        ap.error("--min-hunk must be >= 1")
    if len(set(a.prs)) != len(a.prs):
        ap.error("--prs contains duplicates")
    repo = a.repo
    base = rev(repo, a.base)
    if not base:
        raise SystemExit(f"base {a.base} not found in {repo}")
    have_wt = "--write-tree" in git(repo, "merge-tree", "-h", check=False).stdout + \
              git(repo, "merge-tree", "-h", check=False).stderr

    pr, H = {}, {}
    for n in a.prs:
        head = rev(repo, a.pr_ref.replace("{n}", str(n)))
        if not head:
            pr[n] = {"error": "no head (fetch refs/pull/<n>/head first)"}; continue
        bm = best_merge_base(repo, base, head)
        if not bm:
            pr[n] = {"error": "no merge base with base"}; continue
        mb, surf = bm
        pr[n] = {"head": head, "merge_base": mb, "surface": surf, "merge": merge_status(repo, base, head, have_wt, mb)}
        H[n] = hunks(repo, mb, head)

    ok = [n for n in a.prs if "error" not in pr[n]]
    errs = [n for n in a.prs if "error" in pr[n]]
    pairs = []
    for x in ok:
        for y in ok:
            if x != y:
                c = overlap(H[x], H[y], a.min_hunk)
                if c:
                    pairs.append({"x": x, "y": y, "overlap": c, "surface_y": pr[y]["surface"]})
    score = collections.Counter()
    for p in pairs:
        score[p["x"]] += p["overlap"]

    # exact-hunk union: sum of distinct (file, hunk) strings >= min_hunk. total_hunk - union is an estimate of
    # duplicated hunk-lines under exact matching, not a rigorous line-level bound (nested hunks can overlap).
    hlen, seen = {}, set()
    for n in ok:
        for f, hs in H[n].items():
            for h in hs:
                if hunklen(h) >= a.min_hunk:
                    hlen[(f, h)] = hunklen(h); seen.add((f, h))
    total_hunk = sum(hlen[(f, h)] for n in ok for f, hs in H[n].items() for h in hs if (f, h) in hlen)
    union = sum(hlen[k] for k in seen)
    total_surface = sum(pr[n]["surface"] for n in ok)
    ncon = sum(1 for n in ok if pr[n]["merge"] != "clean")
    res = {"schema_version": 1, "base": base, "min_hunk": a.min_hunk,
           "prs": {str(n): pr[n] for n in a.prs}, "pairs": sorted(pairs, key=lambda p: -p["overlap"]),
           "score": dict(score.most_common()), "surface_total": total_surface,
           "exact_hunk_union": union, "hunk_lines_total": total_hunk}

    if a.roots:
        r = root_analysis({n: H[n] for n in ok}, a.min_hunk)
        res["roots"] = r
        if a.json:
            write_json(res, a.json)
        print(f"base {base[:12]}  PRs {len(ok)}  surface {total_surface} lines; hunk-lines {total_hunk}, "
              f"unique exact hunks {union} (~{total_hunk - union} duplicated under exact matching); "
              f"{ncon} do not merge cleanly into base")
        print("\nshared-text blocks (a block = hunks with the same owner-set; projected reduction = lines x (owners-1), textual only)")
        print("  lines  reduc  in     carrier  files")
        for c in r["groups"][:a.top]:
            root = f"#{c['root']}" if c["root"] else "none"
            files = ", ".join(c["files"][:4]) + (f" +{len(c['files'])-4}" if len(c["files"]) > 4 else "")
            owns = ", ".join("#" + str(p) for p in c["owners"][:8]) + ("…" if len(c["owners"]) > 8 else "")
            print(f"  {c['lines']:>5}  {c['save']:>5}  {len(c['owners']):>2}PRs  {root:<8} {files}  [{owns}]")
        print("\nper PR: own changed lines vs textual overlap with other PRs (exact hunk matching)")
        for n in sorted(r["per_pr"], key=lambda n: -r["per_pr"][n]["shared"]):
            p = r["per_pr"][n]; cl = "" if pr[n]["merge"] == "clean" else f" [{pr[n]['merge']}]"
            print(f"  #{n:<5} own {p['own']:>5}   shared {p['shared']:>5}{cl}")
        top = r["groups"][0] if r["groups"] else None
        if top and top["root"]:
            print(f"\n=> smallest carrier of the largest shared text: #{top['root']} ({top['lines']} lines shared by "
                  f"{len(top['owners'])} PRs; least other baggage). Landing that text once would remove ~{top['lines']} lines "
                  f"from each other carrier's review. Triage, not merge-order authority: the carrier is not the text's origin.")
        elif top:   # cannot occur under owner-set grouping (see root_analysis KNOWN LIMITATION); kept for a future grouping
            print(f"\n=> the {top['lines']}-line text shared by {len(top['owners'])} PRs has no single carrier.")
        if errs:
            print(f"\nnot measured: {', '.join('#' + str(n) for n in errs)}")
        return 2 if errs else 0

    print(f"base {base[:12]}  PRs {len(a.prs)} (measured {len(ok)})  surface {total_surface} lines; "
          f"~{total_hunk - union} hunk-lines of textual overlap (exact matching)  not merging cleanly: {ncon}")
    print("\nland first -> projected reduction of review lines in other PRs (after they rebase; textual overlap, not semantic ownership)")
    for x, s in score.most_common(a.top):
        ys = sorted((p for p in pairs if p["x"] == x), key=lambda p: -p["overlap"])
        shown = ", ".join(f"#{p['y']} {p['overlap']}" for p in ys[:6]) + (f", +{len(ys)-6} more" if len(ys) > 6 else "")
        flag = "" if pr[x]["merge"] == "clean" else f"  [{pr[x]['merge']}]"
        print(f"  #{x:<5} {s:>6}  (surface {pr[x]['surface']}, in {len(ys)} PRs: {shown}){flag}")
    if a.json:
        write_json(res, a.json)
    if errs:
        print(f"\nnot measured: {', '.join('#' + str(n) for n in errs)}")
    return 2 if errs else 0

# Roadmap (deferred): add a MEASURED-RESIDUAL mode (synthetically land X, rebase/merge each Y, recompute the
# residual diff + conflicts) so sequencing is evidence and a true no-owner shared change surfaces; decide order by
# semantic ownership + ancestry + measured residual, not carrier size; retain @@ hunk coordinates for positional
# matching and line-numbered extract hints; a fuzzy/whitespace-insensitive match mode reported separately from
# exact; a greedy total order (pick a root, subtract its block, repeat) instead of one tip; overlap as a share of
# each PR's surface; --fetch and --prs-from to drop the hand-built list; fixture tests (deletion not grouped under
# /dev/null, trailing-ws preserved, nested-hunk containment, root identification).

if __name__ == "__main__":
    sys.exit(main())
