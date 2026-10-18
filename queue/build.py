#!/usr/bin/env python3
"""build.py: the review-queue pages, from public GitHub data and this tree's patches.json files.

Two pages, rendered to site/: the index is the *needs a review* track (open pull requests with no review at their
current head, ranked by risk tier, then age, then size), and site/maintainers/ is the *needs a maintainer* track
(reviewed, CI green, mergeable; ranked by days waiting), opening with the open upstream pull requests this test suite
carries as patches, because merging one of those lets a scenario read true on the plain release (one already merged into a
development branch is listed apart, at the end: carried until a release contains it, nothing for a maintainer). The
ranking rules are data (queue/rules.json) and every row shows the rule lines that placed it. Every author is scored the
same way.

    GITHUB_TOKEN=... python3 queue/build.py [--repo ergoplatform/ergo] [--out site] [--limit N]

Standard library and git. Reads: the repository's open pull requests, their files, reviews, issue comments, head commit
and check runs (public data), and, for the same-change view, each open pull request's head fetched into a blobless bare
clone (--git-cache; kept between local runs, fresh on a hosted runner). Writes: <out>/index.html,
<out>/maintainers/index.html, <out>/queue.json. A pull request
reviewed with peeryard at its current head (an issue comment carrying "using peeryard" or the earlier "using
forkbench", posted after the head commit) is shown with that review's link instead of being offered for one.
"""
import argparse, datetime as dt, fnmatch, html, json, os, re, subprocess, sys, time, urllib.error, urllib.parse, urllib.request

API = "https://api.github.com"
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)


def now_utc():
    return dt.datetime.now(dt.timezone.utc)


def parse_ts(s):
    return dt.datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=dt.timezone.utc)


def api(path, params=None, token=None, paginate=False):
    url = API + path + ("?" + urllib.parse.urlencode(params) if params else "")
    out = []
    while url:
        req = urllib.request.Request(url, headers={"Accept": "application/vnd.github+json",
                                                   "User-Agent": "peeryard-queue",
                                                   **({"Authorization": f"Bearer {token}"} if token else {})})
        for attempt in range(4):
            try:
                with urllib.request.urlopen(req, timeout=60) as r:
                    data = json.loads(r.read().decode())
                    link = r.headers.get("Link", "")
                    break
            except urllib.error.HTTPError as e:
                if e.code in (403, 429) and attempt < 3:
                    time.sleep(30 * (attempt + 1)); continue
                raise
        if not paginate:
            return data
        out.extend(data)
        url = None
        for part in link.split(","):
            if 'rel="next"' in part:
                url = part.split(";")[0].strip().strip("<>")
    return out


def load_rules():
    with open(os.path.join(HERE, "rules.json")) as f:
        return json.load(f)


def tier_of(files, rules):
    """The lowest tier number (highest risk) any changed production file falls in; tests and docs alone are the last tier."""
    best = None
    for f in files:
        for rule in rules["tiers"]:
            if any(fnmatch.fnmatch(f, pat) for pat in rule["paths"]):
                if best is None or rule["tier"] < best[0]:
                    best = (rule["tier"], rule["name"])
                break
    return best or (rules["default_tier"], "other")


def carried_patches():
    """Open upstream pull requests this tree carries as patches, with the scenarios that need them."""
    rows = {}
    pdir = os.path.join(ROOT, "patches")
    for d in sorted(os.listdir(pdir)):
        pj = os.path.join(pdir, d, "patches.json")
        if not os.path.isfile(pj):
            continue
        with open(pj) as f:
            j = json.load(f)
        for p in j["patches"]:
            pr = p.get("upstream_pr")
            if not pr or p.get("status") in ("candidate", "withdrawn") or str(p.get("status", "")).startswith("merged-in-"):
                continue
            key = (j["repo"], int(pr))
            row = rows.setdefault(key, {"repo": j["repo"], "number": int(pr), "patches": [], "needed_by": set(), "status": p["status"]})
            row["patches"].append(f"{d}/{p['id']}")
            row["needed_by"].update(p.get("needed_by") or [])
    for r in rows.values():
        r["needed_by"] = sorted(r["needed_by"])
    return list(rows.values())


def collect(repo, token, limit):
    """Returns (rows for the open, non-draft pull requests; the open pull-request list as GitHub gave it, drafts included)."""
    allprs = api(f"/repos/{repo}/pulls", {"state": "open", "per_page": 100}, token, paginate=True)
    prs = [p for p in allprs if not p["draft"]][: limit or None]
    allprs = allprs[: limit or None]
    rows = []
    for p in prs:
        n = p["number"]
        full = api(f"/repos/{repo}/pulls/{n}", token=token)
        # GitHub computes mergeability lazily: after the base branch moves, the first read says "unknown" and starts the
        # computation. Ask again before judging; a pull request still unknown stays on the track (see rank_maintainer).
        for wait in (3, 6, 12):
            if full.get("mergeable_state") != "unknown":
                break
            time.sleep(wait)
            full = api(f"/repos/{repo}/pulls/{n}", token=token)
        files = [f["filename"] for f in api(f"/repos/{repo}/pulls/{n}/files", {"per_page": 100}, token, paginate=True)]
        head_sha = full["head"]["sha"]
        head = api(f"/repos/{repo}/commits/{head_sha}", token=token)
        head_at = parse_ts(head["commit"]["committer"]["date"])
        reviews = api(f"/repos/{repo}/pulls/{n}/reviews", {"per_page": 100}, token, paginate=True)
        comments = api(f"/repos/{repo}/issues/{n}/comments", {"per_page": 100}, token, paginate=True)
        checks = api(f"/repos/{repo}/commits/{head_sha}/check-runs", {"per_page": 100}, token).get("check_runs", [])
        reviews_at_head = [r for r in reviews if r.get("submitted_at") and parse_ts(r["submitted_at"]) > head_at
                           and r["user"]["login"] != full["user"]["login"]]
        peeryard = [c for c in comments if parse_ts(c["created_at"]) > head_at
                    and ("using peeryard" in c["body"].lower() or "using forkbench" in c["body"].lower())]
        last_activity = max([head_at] + [parse_ts(r["submitted_at"]) for r in reviews_at_head]
                            + [parse_ts(c["created_at"]) for c in comments if parse_ts(c["created_at"]) > head_at])
        if checks:
            concl = {c["conclusion"] for c in checks if c["status"] == "completed"}
            pending = any(c["status"] != "completed" for c in checks)
            ci = "pending" if pending else ("green" if concl <= {"success", "neutral", "skipped"} else "red")
        else:
            ci = "none"
        body = full.get("body") or ""
        rows.append({
            "number": n, "title": full["title"], "author": full["user"]["login"], "url": full["html_url"],
            "base": full["base"]["ref"], "head_sha": head_sha[:9], "head_at": head_at.isoformat(),
            "files": len(files), "additions": full["additions"], "deletions": full["deletions"],
            "tier": tier_of(files, RULES), "reviews_at_head": len(reviews_at_head),
            "approved_at_head": any(r["state"] == "APPROVED" for r in reviews_at_head),
            "peeryard_review": peeryard[-1]["html_url"] if peeryard else None,
            "mergeable": full.get("mergeable_state"), "ci": ci,
            "linked_issue": any(k in body.lower() for k in ("fixes #", "closes #", "resolves #")),
            "days_at_head": (now_utc() - head_at).days, "days_waiting": (now_utc() - last_activity).days,
        })
    return rows, allprs


# ---- same change: open pull requests whose production diffs are identical, or that address one issue -------------------

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
        git(gdir, "-c", "fetch.negotiationAlgorithm=noop", "fetch", "-q", "origin", "--no-tags", "--no-write-fetch-head",
            "--recurse-submodules=no", "--filter=blob:none", "--stdin", stdin="".join(o + "\n" for o in sorted(blobs)))
    for n, (mb, head, files) in ranges.items():
        try:
            pid = None
            if files:
                patch = git(gdir, "diff", "--no-renames", "--no-color", "--no-ext-diff", mb, head, "--", *PROD_PATHSPEC)
                pid = (git(gdir, "patch-id", "--stable", stdin=patch).split() or [None])[0]
            out[n] = {"files": files, "patch_id": pid}
        except Exception as e:
            out[n] = {"files": None, "patch_id": None, "error": str(e)[:200]}
    return out


def issue_refs(repo, p):
    """Numbers a pull request's title or body points at (#N, or a link to an issue or pull request of this repo)."""
    text = (p.get("title") or "") + "\n" + (p.get("body") or "")
    nums = {int(m) for m in re.findall(r"(?<![\w/&])#(\d+)\b", text)}
    nums |= {int(m) for m in re.findall(rf"github\.com/{re.escape(repo)}/(?:issues|pull)/(\d+)", text)}
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
    by_pid = {}
    for n, d in diffs.items():
        if d.get("patch_id"):
            by_pid.setdefault(d["patch_id"], []).append(n)
    exact = []
    for pid, ns in by_pid.items():
        if len(ns) > 1:
            ns.sort(key=lambda n: (meta[n]["created"], n))
            exact.append({"patch_id": pid, "prs": ns, "files": diffs[ns[0]]["files"]})
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


def is_wip(r):
    t = r["title"].upper()
    return any(m.upper() in t for m in RULES.get("wip_markers", []))


def rank_review(rows):
    """Needs a review: no review at the current head, head pushed within stale_days, not marked WIP. Order: tier,
    then longest at the current head, then smallest."""
    stale = RULES.get("stale_days", 90)
    todo = [r for r in rows if r["reviews_at_head"] == 0 and not r["peeryard_review"] and r["days_at_head"] <= stale and not is_wip(r)]
    todo.sort(key=lambda r: (r["tier"][0], -r["days_at_head"], r["additions"] + r["deletions"]))
    for r in todo:
        r["why"] = [f"tier {r['tier'][0]} ({r['tier'][1]})", f"{r['days_at_head']} days at this head",
                    f"{r['additions']}+/{r['deletions']}- in {r['files']} files",
                    "links an issue" if r["linked_issue"] else "no linked issue", f"CI {r['ci']}"]
    return todo


def rank_maintainer(rows):
    """Needs a maintainer: reviewed at this head, CI green (or none), mergeable. Order: longest waiting first."""
    todo = [r for r in rows if r["reviews_at_head"] > 0 and r["ci"] in ("green", "none") and r["mergeable"] in ("clean", "unstable", "has_hooks", "unknown")]
    todo.sort(key=lambda r: (-r["days_waiting"], r["tier"][0]))
    for r in todo:
        r["why"] = [f"{r['days_waiting']} days since the last activity", f"{r['reviews_at_head']} review(s) at this head"
                    + (", approved" if r["approved_at_head"] else ""), f"CI {r['ci']}", ("mergeable: not yet computed by GitHub" if r["mergeable"] == "unknown" else f"mergeable: {r['mergeable']}"),
                    f"tier {r['tier'][0]} ({r['tier'][1]})"]
    return todo


CSS = """body{font:15px/1.45 system-ui,sans-serif;max-width:64rem;margin:2rem auto;padding:0 1rem;color:#222}
h1,h2{font-weight:600}table{border-collapse:collapse;width:100%}td,th{padding:.35rem .5rem;border-bottom:1px solid #ddd;vertical-align:top;text-align:left}
small{color:#555}.why{color:#555;font-size:.85em}a{color:#0645ad;text-decoration:none}a:hover{text-decoration:underline}
nav a{margin-right:1rem}.tag{display:inline-block;padding:0 .35rem;border:1px solid #bbb;border-radius:3px;font-size:.8em;margin-left:.3rem}"""


def page(title, sections, generated, repo, path_prefix=""):
    h = [f"<!doctype html><meta charset=utf-8><title>{html.escape(title)}</title><style>{CSS}</style>",
         f"<nav><a href='{path_prefix}./'>needs a review</a><a href='{path_prefix}maintainers/'>needs a maintainer</a>"
         f"<a href='https://github.com/cafebedouin/peeryard'>peeryard</a><a href='https://github.com/cafebedouin/peeryard/blob/main/queue/rules.json'>the rules</a></nav>",
         f"<h1>{html.escape(title)}</h1><p><small>Open pull requests of <a href='https://github.com/{repo}/pulls'>{repo}</a>, "
         f"generated {generated} from public GitHub data by <a href='https://github.com/cafebedouin/peeryard/blob/main/queue/build.py'>queue/build.py</a>. "
         f"Every author is ranked by the same rules; a disagreement with a rank is a pull request against <code>queue/rules.json</code>.</small></p>"]
    for heading, intro, rows, cols in sections:
        h.append(f"<h2>{html.escape(heading)}</h2><p><small>{intro}</small></p>")
        if not rows:
            h.append("<p><small>nothing here today</small></p>"); continue
        h.append("<table><tr>" + "".join(f"<th>{c}</th>" for c in cols) + "</tr>")
        for r in rows:
            h.append("<tr>" + "".join(f"<td>{c}</td>" for c in r) + "</tr>")
        h.append("</table>")
    return "\n".join(h) + "\n"


def pr_cell(r):
    return (f"<a href='{r['url']}'>#{r['number']}</a> {html.escape(r['title'])}<br><small>{html.escape(r['author'])}, "
            f"base {html.escape(r['base'])}, head {r['head_sha']}</small>" + same_note(r))


def same_note(r):
    notes = []
    if r.get("same_change_as"):
        notes.append(f"same production change as #{r['same_change_as']} (opened earlier)")
    elif r.get("same_change_later"):
        notes.append("same production change also in " + ", ".join(f"#{n}" for n in r["same_change_later"]) + " (opened later)")
    for s in r.get("same_issue") or []:
        notes.append(f"same issue #{s['issue']} as " + ", ".join(f"#{n}" for n in s["with"]) + " (overlapping files)")
    return "".join(f"<br><small class=tag>{html.escape(n)}</small>" for n in notes)


def pr_ref(m):
    return (f"<a href='{m['url']}'>#{m['number']}</a> <small>{html.escape(m['author'])}, opened {m['created'][:10]}, "
            f"base {html.escape(m['base'])}{', draft' if m['draft'] else ''}</small>")


def same_change_sections(exact, related, meta, error, uncompared):
    intro_tail = f" <b>Not computed today</b> ({html.escape(error)})." if error else ""
    if uncompared:
        intro_tail += " Not compared today (their diff could not be read): " + ", ".join(f"#{n}" for n in uncompared) + "."
    ex_rows = []
    for g in exact:
        first, rest = g["prs"][0], g["prs"][1:]
        ex_rows.append(("<br>".join(pr_ref(meta[n]) for n in g["prs"]),
                        f"<span class=why>{len(rest)} later pull request(s) with the same production diff as #{first} (opened "
                        f"earlier); {len(g['files'])} production file(s): {html.escape(', '.join(os.path.basename(f) for f in g['files']))}</span>"))
    rel_rows = []
    for g in related:
        pairs = "; ".join(f"#{p['prs'][0]} and #{p['prs'][1]} share {p['shared_files']} production file(s)" for p in g["pairs"])
        rel_rows.append((f"<a href='{html.escape(g['url'])}'>issue #{g['issue']}</a> {html.escape(g['title'])} <small>({html.escape(g['state'])})</small>",
                         "<br>".join(pr_ref(meta[n]) for n in g["prs"]), f"<span class=why>{pairs}</span>"))
    return [
        ("Open pull requests that make the same change", "Open pull requests (drafts included) whose production diff "
         "(<code>src/main</code> and <code>*/src/main</code>, from the merge base with their base branch) is identical by "
         "<code>git patch-id --stable</code>; earliest opened first. Tests, docs and base branch may differ." + intro_tail,
         ex_rows, ["pull requests", "what they share"]),
        ("Open pull requests on the same issue", "Open pull requests by different authors that reference the same issue and "
         "change at least one of the same production files: alternatives a maintainer may want to read together. A pair "
         "already listed as the same change, and a release candidate (a pull request from a release branch), are left out."
         + intro_tail, rel_rows, ["issue", "pull requests", "overlap"]),
    ]


def carried_state_cell(c, token):
    """A carried pull request missing from the open, non-draft list: say what it is (draft, closed, merged), from public data.
    Returns (cell, merged_into): merged_into is the base branch of a merged pull request, else None."""
    repo, n = c["repo"], c["number"]
    link = f"<a href='https://github.com/{repo}/pull/{n}'>#{n}</a>"
    try:
        p = api(f"/repos/{repo}/pulls/{n}", token=token)
    except Exception:
        return f"{link} (state not readable today)", None
    title = html.escape(p.get("title", ""))
    if p["state"] == "open":
        kind = "open as a draft" if p.get("draft") else "open"
        return f"{link} {title}<br><small>{html.escape(p['user']['login'])}, base {html.escape(p['base']['ref'])}, {kind}</small>", None
    if p.get("merged_at"):
        # still in patches.json without merged-in-<tag>: the release the rig uses does not contain it yet
        base = p["base"]["ref"]
        return (f"{link} {title}<br><small>merged into {html.escape(base)}, carried until release (merged {p['merged_at'][:10]}; "
                f"the patch leaves the stack with the release that contains it)</small>", base)
    base = p["base"]["ref"]
    try:
        api(f"/repos/{repo}/branches/{urllib.parse.quote(base, safe='')}", token=token); base_note = ""
    except urllib.error.HTTPError as e:
        base_note = f" (its base branch {html.escape(base)} no longer exists)" if e.code == 404 else ""
    issues = []
    for m in re.finditer(r"(?i)\b(?:fixes|closes|resolves)\s+#(\d+)", p.get("body") or ""):
        num = int(m.group(1))
        try:
            st = api(f"/repos/{repo}/issues/{num}", token=token)["state"]
        except Exception:
            st = "state unknown"
        issues.append(f"<a href='https://github.com/{repo}/issues/{num}'>#{num}</a> {st}")
    fixes = f"; fixes {', '.join(issues)}" if issues else ""
    return f"{link} {title}<br><small>closed unmerged {(p.get('closed_at') or '')[:10]}{base_note}{fixes}</small>", None


def why_cell(r):
    return "<span class=why>" + "; ".join(html.escape(w) for w in r["why"]) + "</span>"


def main():
    global RULES
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", default="ergoplatform/ergo")
    ap.add_argument("--out", default=os.path.join(ROOT, "site"))
    ap.add_argument("--limit", type=int, default=0, help="only the first N open PRs (for a local test)")
    ap.add_argument("--git-cache", default=os.path.join(os.path.expanduser("~"), ".cache", "peeryard", "queue"),
                    help="where the blobless bare clone for the same-change view lives (kept between runs)")
    a = ap.parse_args()
    token = os.environ.get("GITHUB_TOKEN")
    RULES = load_rules()
    rows, allprs = collect(a.repo, token, a.limit)
    by_number = {r["number"]: r for r in rows}
    t0, sc_error = time.time(), None
    try:
        diffs = production_diffs(a.repo, allprs, os.path.join(a.git_cache, a.repo.replace("/", "_") + ".git"))
        exact, related, meta = same_change(a.repo, allprs, diffs, token, RULES)
    except Exception as e:                       # the view is an extra: the pages still render without it
        diffs, exact, related, meta, sc_error = {}, [], [], {}, str(e)[:200]
    for n, d in diffs.items():
        if n in by_number:
            by_number[n]["production_patch_id"] = d.get("patch_id")
            by_number[n]["production_files"] = d.get("files")
    for g in exact:
        for n in g["prs"][1:]:
            if n in by_number:
                by_number[n]["same_change_as"] = g["prs"][0]
        if g["prs"][0] in by_number:
            by_number[g["prs"][0]]["same_change_later"] = g["prs"][1:]
    for g in related:
        for n in g["prs"]:
            if n in by_number:
                others = sorted({m for p in g["pairs"] if n in p["prs"] for m in p["prs"]} - {n})
                by_number[n].setdefault("same_issue", []).append({"issue": g["issue"], "with": others})
    sc_secs = round(time.time() - t0)
    uncompared = sorted(n for n, d in diffs.items() if d.get("error"))
    review = rank_review(rows)
    maint = rank_maintainer(rows)
    stale_days = RULES.get("stale_days", 90)
    stale = sorted([r for r in rows if r["days_at_head"] > stale_days], key=lambda r: -r["days_at_head"])
    wip = [r for r in rows if is_wip(r) and r["days_at_head"] <= stale_days]
    carried = [c for c in carried_patches() if c["repo"] == a.repo]
    carried.sort(key=lambda c: (-len(c["needed_by"]), c["number"]))
    generated = now_utc().strftime("%Y-%m-%d %H:%M UTC")
    os.makedirs(os.path.join(a.out, "maintainers"), exist_ok=True)
    reviewed = [r for r in rows if r["peeryard_review"]]
    same_secs = same_change_sections(exact, related, meta, sc_error, uncompared)

    cols = ["pull request", "why here"]
    index = page("Ergo node pull requests that need a review", [
        ("Needs a review", "No review at the current head, ranked by risk tier (consensus, sync and state first), then by how long "
         "the head has waited, then by size. An agent reviews one with peeryard's <code>AGENTS.md</code>; a person with "
         "the same steps. Pick from the top.", [(pr_cell(r), why_cell(r)) for r in review], cols),
        *same_secs,
        ("Reviewed with peeryard at this head", "Shown so nobody does the same review twice; the link is the review.",
         [(pr_cell(r), f"<a href='{r['peeryard_review']}'>review</a>") for r in reviewed], ["pull request", "review"]),
        ("Marked WIP by their authors", "Not ranked; listed so they are not forgotten.",
         [(pr_cell(r), f"<span class=why>{r['days_at_head']} days at this head</span>") for r in wip], cols),
        (f"Older than {stale_days} days at their head ({len(stale)})", "Unranked. A pull request comes back into the work list when its author pushes.",
         [(f"<a href='{r['url']}'>#{r['number']}</a> {html.escape(r['title'])} <small>({html.escape(r['author'])}, {r['days_at_head']} d)</small>" + same_note(r), "") for r in stale], ["pull request", ""]),
    ], generated, a.repo)
    carried_rows, merged_rows = [], []
    for c in carried:
        r = by_number.get(c["number"])
        cell, c["merged_into"] = (pr_cell(r), None) if r else carried_state_cell(c, token)
        why = (f"<span class=why>carried as {', '.join(c['patches'])} ({c['status']}); "
               f"unblocks {len(c['needed_by'])} example(s): {html.escape(', '.join(c['needed_by']) or 'none named')}</span>")
        (merged_rows if c["merged_into"] else carried_rows).append((cell, why))
    maint_page = page("Ergo node pull requests that need a maintainer", [
        ("Pull requests the peeryard test suite depends on", "Upstream pull requests carried as patches in the reference node; "
         "merging one lets an example read true on the plain release. Ranked by how many examples need it. A row that is not an "
         "open, ready pull request says what it is instead (a draft, or closed with the issue it fixes still open).", carried_rows, ["pull request", "why here"]),
        ("Needs a maintainer", "Reviewed at the current head, CI green, mergeable; ranked by days since the last activity.",
         [(pr_cell(r), why_cell(r)) for r in maint], cols),
        *same_secs,
        ("Merged upstream, carried until release", "Carried pull requests already merged into a development branch: nothing "
         "for a maintainer to do. The reference node is a release that does not contain them yet, so the patches stay until "
         "a release does.", merged_rows, ["pull request", "why here"]),
    ], generated, a.repo, path_prefix="../")
    with open(os.path.join(a.out, "index.html"), "w") as f:
        f.write(index)
    with open(os.path.join(a.out, "maintainers", "index.html"), "w") as f:
        f.write(maint_page)
    with open(os.path.join(a.out, "queue.json"), "w") as f:
        json.dump({"generated": generated, "repo": a.repo, "needs_review": [r["number"] for r in review],
                   "needs_maintainer": [r["number"] for r in maint], "carried": carried,
                   "same_change": exact, "same_issue": related, "same_change_error": sc_error,
                   "same_change_uncompared": uncompared, "rows": rows}, f, indent=1, default=str)
    print(f"{len(rows)} open PRs: {len(review)} need a review, {len(maint)} need a maintainer, {len(reviewed)} reviewed with peeryard, "
          f"{len(carried)} carried; same change: {len(exact)} group(s), same issue: {len(related)} group(s) ({sc_secs} s"
          + (f", not computed: {sc_error}" if sc_error else "") + f"); written to {a.out}")


if __name__ == "__main__":
    main()
