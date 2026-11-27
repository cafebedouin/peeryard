"""samechange.py: the same-change view: open pull requests whose production diffs are identical (git patch-id over
src/main and */src/main, from one blobless bare clone), or that address one issue; and a review carried across a
rebase or a tests-only push. Part of queue/build.py (see its docstring)."""
import os, re, subprocess, sys

from ghapi import api


def carry_reviews(repo, rows, diffs, gdir):
    """A peeryard review made at an earlier head still stands when the production diff is unchanged: the marker's
    prod_patch_id, or the -U0 production patch-id computed at the reviewed head (the marker's head, or the review's
    commit_id), equals the current one. Sets peeryard_review and peeryard (carried_from = the reviewed head). A
    comment without a marker names no head and cannot carry."""
    carried = 0
    for r in rows:
        p = r.get("peeryard_prior")
        cur = (diffs.get(r["number"]) or {}).get("patch_id")
        if not p or not cur:
            continue
        pid = p.get("prod_patch_id")
        if not pid and p.get("head"):
            try:
                if subprocess.run(["git", "--git-dir", gdir, "cat-file", "-e", p["head"] + "^{commit}"], capture_output=True).returncode:
                    git(gdir, "fetch", "-q", "--no-tags", "origin", p["head"])
                mb = git(gdir, "merge-base", f"refs/heads/{r['base']}", p["head"]).split()[0]
                pid, _ = production_patch_id(gdir, mb, p["head"], "-U0")
            except Exception:
                pid = None
        if pid and pid == cur:
            r["peeryard_review"] = p["url"]
            r["peeryard"] = dict(p, carried_from=p["head"][:9] if p.get("head") else None, prod_patch_id=pid)
            carried += 1
    for r in rows:
        r.pop("peeryard_prior", None)
    return carried



PROD_PATHSPEC = [":(glob)src/main/**", ":(glob)*/src/main/**"]


def git(gdir, *args, stdin=None):
    r = subprocess.run(["git", "--git-dir", gdir, *args], input=stdin, capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError(f"git {' '.join(args[:3])}: {r.stderr.strip()[:300]}")
    return r.stdout


def production_diffs(repo, prs, gdir):
    """For each open pull request (drafts included): the production files its diff changes and the stable patch-id of
    that diff, merge-base(base, head)..head restricted to src/main and */src/main. One blobless bare clone; the heads
    are fetched in one call, then the blobs the diffs read in one more (a lazy fetch per diff costs minutes)."""
    if not os.path.isdir(gdir):
        os.makedirs(os.path.dirname(gdir), exist_ok=True)
        subprocess.run(["git", "clone", "-q", "--bare", "--filter=blob:none", "--no-tags",
                        f"https://github.com/{repo}.git", gdir], check=True, capture_output=True)
    refspecs = ["+refs/heads/*:refs/heads/*"] + [f"+refs/pull/{p['number']}/head:refs/pull/{p['number']}/head" for p in prs]
    for i in range(0, len(refspecs), 200):
        try:
            git(gdir, "fetch", "-q", "--no-tags", "origin", *refspecs[i:i + 200])
        except RuntimeError:                   # one ref gone since the listing fails the call: fetch the batch one by one
            for spec in refspecs[i:i + 200]:
                try:
                    git(gdir, "fetch", "-q", "--no-tags", "origin", spec)
                except RuntimeError:
                    pass                       # that pull request is reported with its error below
    ranges, out, blobs = {}, {}, set()
    for p in prs:
        n = p["number"]
        try:
            head = p["head"]["sha"]
            if subprocess.run(["git", "--git-dir", gdir, "cat-file", "-e", head + "^{commit}"], capture_output=True).returncode:
                head = git(gdir, "rev-parse", f"refs/pull/{n}/head").strip()   # pushed since GitHub listed it
            base = f"refs/heads/{p['base']['ref']}"
            if subprocess.run(["git", "--git-dir", gdir, "rev-parse", "-q", "--verify", base], capture_output=True).returncode:
                base = p["base"]["sha"]                                        # base branch deleted since
            mb = git(gdir, "merge-base", base, head).split()[0]
            raw = git(gdir, "diff", "--raw", "--no-renames", "--no-abbrev", mb, head, "--", *PROD_PATHSPEC).splitlines()
            blobs.update(o for line in raw for o in line.split()[2:4] if o.strip("0"))
            ranges[n] = (mb, head, [line.split("\t", 1)[1] for line in raw])
        except Exception as e:
            out[n] = {"files": None, "patch_id": None, "error": str(e)[:200]}
    if blobs:   # the same request git makes for one missing blob, made once for all of them
        try:
            git(gdir, "-c", "fetch.negotiationAlgorithm=noop", "fetch", "-q", "origin", "--no-tags", "--no-write-fetch-head",
                "--recurse-submodules=no", "--filter=blob:none", "--stdin", stdin="".join(o + "\n" for o in sorted(blobs)))
        except RuntimeError as e:              # slower, not wrong: each diff below fetches its own blobs, or reports its error
            print(f"same change: the batched blob fetch failed, fetching per diff: {str(e)[:200]}", file=sys.stderr)
    for n, (mb, head, files) in ranges.items():
        try:
            pid = pid_ctx = None
            changed = 0
            if files:
                pid, changed = production_patch_id(gdir, mb, head, "-U0")
                pid_ctx, _ = production_patch_id(gdir, mb, head)
            out[n] = {"files": files, "patch_id": pid, "patch_id_context": pid_ctx, "changed_lines": changed}
        except Exception as e:
            out[n] = {"files": None, "patch_id": None, "error": str(e)[:200]}
    return out


def production_patch_id(gdir, mb, head, *opts):
    """(git patch-id --stable of the production diff mb..head, number of changed lines). With -U0 the diff carries the
    changed lines only, so one change applied on top of a different base (other neighbouring lines) keeps its id; without
    it, the id also covers three lines of context on each side."""
    patch = git(gdir, "diff", *opts, "--no-renames", "--no-color", "--no-ext-diff", mb, head, "--", *PROD_PATHSPEC)
    changed = sum(1 for line in patch.splitlines()
                  if line[:1] in "+-" and not line.startswith(("+++ ", "--- ")))
    return (git(gdir, "patch-id", "--stable", stdin=patch).split() or [None])[0], changed


LEAD_WORDS = r"(?:fix(?:es|ed)?|close[sd]?|resolve[sd]?|address(?:es|ed)?|refs?|references?|part\s+of)"


def issue_refs(repo, p):
    """Numbers a pull request says it addresses: #N or a link to an issue or pull request of this repo in the title, or
    in the body right after a lead word (fix, close, resolve and their forms; addresses, refs, references, part of;
    "issue" may follow it, as in "ref: issue #12"), with further numbers joined by commas or "and", or opening the body
    ("See <link>", "Issue: #12", or the reference alone on its first line). A number the body only cites later ("see
    #12" mid-text, "first assignment (#13)") is not counted: descriptions name neighbouring issues for context, and
    counting those grouped unrelated pull requests."""
    one = rf"(?:(?<![\w/&])#(\d+)\b|github\.com/{re.escape(repo)}/(?:issues|pull)/(\d+))"
    one_nc = one.replace("(\\d+)", "\\d+")

    def nums_in(s):
        return {int(a or b) for a, b in re.findall(one, s)}
    nums = nums_in(p.get("title") or "")
    item = rf"#?(?:https?://)?{one_nc}"
    refs = rf"((?:issues?\s+)?{item}(?:\s*(?:,|\band\b|&)\s*{item})*)"
    body = p.get("body") or ""
    for m in re.finditer(rf"\b{LEAD_WORDS}\b:?\s*{refs}", body, re.IGNORECASE):
        nums |= nums_in(m.group(1))
    first = next((line for line in body.splitlines() if line.strip()), "")
    m = re.match(rf"\s*(?:(?:see|issue|for)\b:?\s*)?{refs}", first, re.IGNORECASE)
    if m:
        nums |= nums_in(m.group(1))
    nums.discard(p["number"])
    return nums


def is_release_merge(repo, p, cfg):
    """A pull request from a release branch of the repository itself (v6.0.9 into master): a release candidate."""
    h = p.get("head") or {}
    return ((h.get("repo") or {}).get("full_name") == repo
            and re.match(cfg.get("release_head", r"^v[0-9]"), h.get("ref") or "") is not None)


def same_change(repo, prs, diffs, token, rules):
    """(exact groups, same-issue groups) over the open pull requests, drafts included. Rules: rules.json tracks.same_change
    and tracks.same_issue."""
    cfg = rules.get("same_change", {})
    meta = {p["number"]: {"number": p["number"], "author": p["user"]["login"], "created": p["created_at"], "draft": p["draft"],
                          "base": p["base"]["ref"], "title": p["title"], "url": p["html_url"]} for p in prs}
    by_pid, min_lines = {}, cfg.get("min_changed_lines", 1)
    for n, d in diffs.items():
        if d.get("patch_id") and d.get("changed_lines", min_lines) >= min_lines:
            by_pid.setdefault(d["patch_id"], []).append(n)
    exact = []
    for pid, ns in by_pid.items():
        if len(ns) > 1:
            ns.sort(key=lambda n: (meta[n]["created"], n))
            exact.append({"patch_id": pid, "prs": ns, "files": diffs[ns[0]]["files"],
                          "changed_lines": diffs[ns[0]].get("changed_lines")})
    exact.sort(key=lambda g: g["prs"][0])
    exact_of = {n: g["patch_id"] for g in exact for n in g["prs"]}
    # same issue: a number referenced by two or more open pull requests, that GitHub says is an issue (not a pull request)
    open_nums = set(meta)
    by_ref = {}
    for p in prs:
        if is_release_merge(repo, p, cfg):
            continue                               # merges a release line: lists the pull requests in it, diff spans them all
        r = issue_refs(repo, p)
        for i in r - open_nums:
            by_ref.setdefault(i, []).append(p["number"])
    related = []
    for i, ns in sorted(by_ref.items()):
        if len({meta[n]["author"] for n in ns}) < 2:
            continue
        try:
            iss = api(f"/repos/{repo}/issues/{i}", token=token)
        except Exception:
            continue
        if "pull_request" in iss:
            continue                               # a merged or closed pull request, not an issue
        pairs = []
        for a in range(len(ns)):
            for b in range(a + 1, len(ns)):
                x, y = ns[a], ns[b]
                if meta[x]["author"] == meta[y]["author"]:
                    continue                       # one author's pull requests on one issue are usually parts of a series
                if exact_of.get(x) and exact_of.get(x) == exact_of.get(y):
                    continue                       # already listed as the same change
                shared = set(diffs.get(x, {}).get("files") or []) & set(diffs.get(y, {}).get("files") or [])
                if shared:
                    pairs.append({"prs": sorted([x, y], key=lambda n: (meta[n]["created"], n)), "shared_files": len(shared)})
        if pairs:
            pairs.sort(key=lambda pr: [(meta[n]["created"], n) for n in pr["prs"]])
            members = sorted({n for pr in pairs for n in pr["prs"]}, key=lambda n: (meta[n]["created"], n))
            related.append({"issue": i, "title": iss.get("title", ""), "state": iss.get("state", ""),
                            "url": iss.get("html_url", ""), "prs": members, "pairs": pairs})
    return exact, related, meta
