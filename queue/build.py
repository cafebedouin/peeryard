#!/usr/bin/env python3
"""build.py: the review-queue pages, from public GitHub data and this tree's patches.json files.

Two pages, rendered to site/: the index is the *needs a review* track (open pull requests with no review at their
current head, ranked by risk tier, then age, then size), and site/maintainers/ is the *needs a maintainer* track
(reviewed, CI green, mergeable; ranked by days waiting), opening with the open upstream pull requests this test suite
carries as patches, because merging one of those lets a scenario read true on the plain release. The ranking rules
are data (queue/rules.json) and every row shows the rule lines that placed it. Every author is scored the same way.

    GITHUB_TOKEN=... python3 queue/build.py [--repo ergoplatform/ergo] [--out site] [--limit N]

Standard library only. Reads: the repository's open pull requests, their files, reviews, issue comments, head commit
and check runs (public data). Writes: <out>/index.html, <out>/maintainers/index.html, <out>/queue.json. A pull request
reviewed with peeryard at its current head (an issue comment carrying "using peeryard" or the earlier "using
forkbench", posted after the head commit) is shown with that review's link instead of being offered for one.
"""
import argparse, datetime as dt, fnmatch, html, json, os, sys, time, urllib.parse, urllib.request

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
    prs = api(f"/repos/{repo}/pulls", {"state": "open", "per_page": 100}, token, paginate=True)
    prs = [p for p in prs if not p["draft"]][: limit or None]
    rows = []
    for p in prs:
        n = p["number"]
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
    return rows


def rank_review(rows):
    """Needs a review: no review at the current head. Order: tier, then oldest head, then smallest."""
    todo = [r for r in rows if r["reviews_at_head"] == 0 and not r["peeryard_review"]]
    todo.sort(key=lambda r: (r["tier"][0], -r["days_at_head"], r["additions"] + r["deletions"]))
    for r in todo:
        r["why"] = [f"tier {r['tier'][0]} ({r['tier'][1]})", f"{r['days_at_head']} days at this head",
                    f"{r['additions']}+/{r['deletions']}- in {r['files']} files",
                    "links an issue" if r["linked_issue"] else "no linked issue", f"CI {r['ci']}"]
    return todo


def rank_maintainer(rows):
    """Needs a maintainer: reviewed at this head, CI green (or none), mergeable. Order: longest waiting first."""
    todo = [r for r in rows if r["reviews_at_head"] > 0 and r["ci"] in ("green", "none") and r["mergeable"] in ("clean", "unstable", "has_hooks")]
    todo.sort(key=lambda r: (-r["days_waiting"], r["tier"][0]))
    for r in todo:
        r["why"] = [f"{r['days_waiting']} days since the last activity", f"{r['reviews_at_head']} review(s) at this head"
                    + (", approved" if r["approved_at_head"] else ""), f"CI {r['ci']}", f"mergeable: {r['mergeable']}",
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
            f"base {html.escape(r['base'])}, head {r['head_sha']}</small>")


def why_cell(r):
    return "<span class=why>" + "; ".join(html.escape(w) for w in r["why"]) + "</span>"


def main():
    global RULES
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", default="ergoplatform/ergo")
    ap.add_argument("--out", default=os.path.join(ROOT, "site"))
    ap.add_argument("--limit", type=int, default=0, help="only the first N open PRs (for a local test)")
    a = ap.parse_args()
    token = os.environ.get("GITHUB_TOKEN")
    RULES = load_rules()
    rows = collect(a.repo, token, a.limit)
    by_number = {r["number"]: r for r in rows}
    review = rank_review(rows)
    maint = rank_maintainer(rows)
    carried = [c for c in carried_patches() if c["repo"] == a.repo]
    carried.sort(key=lambda c: (-len(c["needed_by"]), c["number"]))
    generated = now_utc().strftime("%Y-%m-%d %H:%M UTC")
    os.makedirs(os.path.join(a.out, "maintainers"), exist_ok=True)
    reviewed = [r for r in rows if r["peeryard_review"]]

    cols = ["pull request", "why here"]
    index = page("Ergo node pull requests that need a review", [
        ("Needs a review", "No review at the current head, ranked by risk tier (consensus, sync and state first), then by how long "
         "the head has waited, then by size. An agent reviews one with peeryard's <code>AGENTS.md</code>; a person with "
         "the same steps. Pick from the top.", [(pr_cell(r), why_cell(r)) for r in review], cols),
        ("Reviewed with peeryard at this head", "Shown so nobody does the same review twice; the link is the review.",
         [(pr_cell(r), f"<a href='{r['peeryard_review']}'>review</a>") for r in reviewed], ["pull request", "review"]),
    ], generated, a.repo)
    carried_rows = []
    for c in carried:
        r = by_number.get(c["number"])
        cell = pr_cell(r) if r else f"<a href='https://github.com/{c['repo']}/pull/{c['number']}'>#{c['number']}</a> (not an open pull request today)"
        carried_rows.append((cell, f"<span class=why>carried as {', '.join(c['patches'])} ({c['status']}); "
                             f"unblocks {len(c['needed_by'])} example(s): {html.escape(', '.join(c['needed_by']) or 'none named')}</span>"))
    maint_page = page("Ergo node pull requests that need a maintainer", [
        ("Pull requests the peeryard test suite depends on", "Open upstream pull requests carried as patches in the reference node; "
         "merging one lets an example read true on the plain release. Ranked by how many examples need it.", carried_rows, ["pull request", "why here"]),
        ("Needs a maintainer", "Reviewed at the current head, CI green, mergeable; ranked by days since the last activity.",
         [(pr_cell(r), why_cell(r)) for r in maint], cols),
    ], generated, a.repo, path_prefix="../")
    with open(os.path.join(a.out, "index.html"), "w") as f:
        f.write(index)
    with open(os.path.join(a.out, "maintainers", "index.html"), "w") as f:
        f.write(maint_page)
    with open(os.path.join(a.out, "queue.json"), "w") as f:
        json.dump({"generated": generated, "repo": a.repo, "needs_review": [r["number"] for r in review],
                   "needs_maintainer": [r["number"] for r in maint], "carried": carried, "rows": rows}, f, indent=1, default=str)
    print(f"{len(rows)} open PRs: {len(review)} need a review, {len(maint)} need a maintainer, {len(reviewed)} reviewed with peeryard, "
          f"{len(carried)} carried; written to {a.out}")


if __name__ == "__main__":
    main()
