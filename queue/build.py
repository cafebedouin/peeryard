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
<out>/maintainers/index.html, <out>/queue.json, <out>/history/<date>.json and <out>/history/index.json (the fields and
their stability: docs/queue-data.md). A pull request
reviewed with peeryard at its current head is shown with that review's link instead of being offered for one. A
peeryard review is a pull-request review or an issue comment by someone other than the author that carries the structured marker
`<!-- peeryard {"head": "<sha>", "kind": "...", "prod_patch_id": "..."} -->` (queue/mark.py writes it), or the credit-line
phrase "using peeryard" (the earlier "using forkbench" too), or, for posts made before the marker existed, a credit-line
opening by a login in queue/reviewers.json. A review at an earlier head still counts when the production diff has not
changed since (same `git patch-id --stable` over the changed production lines: a rebase, or a tests-only push); the
page says it was carried and from which head.

The code is in modules beside this file, each imported here so that its names stay reachable as build.<name>
(queue/mark.py and tests/queue_*_test.py use them): ghapi.py (the GitHub client), posts.py (peeryard posts, the review
at the current head, outcomes), samechange.py (the same-change view), rank.py (the rules and the two rankings),
history.py (the daily snapshots) and render.py (the HTML). A test that replaces a function another module calls
replaces it in that module (posts.api, samechange.api, ghapi.api, history.fetch_json).
"""
import argparse, html, json, os, sys, time

import rank
from ghapi import API, api, now_utc, parse_ts, search_numbers  # noqa: F401  (build.<name> for mark.py and the tests)
from history import DATE_RE, SCHEMA_VERSION, fetch_json, load_history, snapshot, write_history  # noqa: F401
from posts import (CREDIT_RE, MARKER_RE, NON_REVIEW_KINDS, PHRASES, head_push_time, load_reviewers,  # noqa: F401
                   outcomes, peeryard_field, peeryard_posts, post_at_head, review_at_head)
from rank import (carried_patches, coverage, is_wip, load_claims, load_rules, needs_rebase, peeryard_note,  # noqa: F401
                  rank_maintainer, rank_review, tier_of)
from render import (CSS, carried_state_cell, coverage_text, page, pr_cell, pr_ref, reviewed_cell,  # noqa: F401
                    same_change_sections, same_note, why_cell)
from samechange import (LEAD_WORDS, PROD_PATHSPEC, carry_reviews, git, is_release_merge, issue_refs,  # noqa: F401
                        production_diffs, production_patch_id, same_change)

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)


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
        head_at, head_at_source = head_push_time(repo, n, head_sha, head, token)
        reviews = api(f"/repos/{repo}/pulls/{n}/reviews", {"per_page": 100}, token, paginate=True)
        comments = api(f"/repos/{repo}/issues/{n}/comments", {"per_page": 100}, token, paginate=True)
        checks = api(f"/repos/{repo}/commits/{head_sha}/check-runs", {"per_page": 100}, token).get("check_runs", [])
        reviews_at_head = [r for r in reviews if review_at_head(r, head_sha, head_at) and r["user"]["login"] != full["user"]["login"]]
        posts = [c for c in peeryard_posts(reviews, comments)
                 if c["login"] != full["user"]["login"] and c["kind"] not in NON_REVIEW_KINDS]   # the author's own posts, replies
        peeryard = [c for c in posts if post_at_head(c, head_sha, head_at)]
        prior = [c for c in posts if not post_at_head(c, head_sha, head_at)]   # the latest one naming a head may still carry (carry_reviews)
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
            "base": full["base"]["ref"], "head_sha": head_sha[:9], "head_at": head_at.isoformat(), "head_at_source": head_at_source,
            "files": len(files), "additions": full["additions"], "deletions": full["deletions"],
            "tier": tier_of(files, RULES), "reviews_at_head": len(reviews_at_head),
            "approved_at_head": any(r["state"] == "APPROVED" for r in reviews_at_head),
            "peeryard_review": peeryard[-1]["url"] if peeryard else None,
            "peeryard": peeryard_field(peeryard[-1]) if peeryard else None,
            "peeryard_prior": next((peeryard_field(c) for c in reversed(prior) if c["head"] or c["commit_id"]), None) if not peeryard else None,
            "mergeable": full.get("mergeable_state"), "ci": ci,
            "linked_issue": any(k in body.lower() for k in ("fixes #", "closes #", "resolves #")),
            "days_at_head": (now_utc() - head_at).days, "days_waiting": (now_utc() - last_activity).days,
        })
    return rows, allprs


def main():
    global RULES
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", default="ergoplatform/ergo")
    ap.add_argument("--out", default=os.path.join(ROOT, "site"))
    ap.add_argument("--limit", type=int, default=0, help="only the first N open PRs (for a local test)")
    ap.add_argument("--git-cache", default=os.path.join(os.path.expanduser("~"), ".cache", "peeryard", "queue"),
                    help="where the blobless bare clone for the same-change view lives (kept between runs)")
    ap.add_argument("--history-from", default=None,
                    help="where the snapshots so far are read from: the published site's base URL, or a local directory "
                         "with history/ (default: --out itself, so local runs accumulate)")
    a = ap.parse_args()
    token = os.environ.get("GITHUB_TOKEN")
    RULES = rank.RULES = load_rules()
    prior = load_history(a.history_from or a.out)        # first, so an unreadable history fails before any work
    rows, allprs = collect(a.repo, token, a.limit)
    by_number = {r["number"]: r for r in rows}
    t0, sc_error = time.time(), None
    gdir = os.path.join(a.git_cache, a.repo.replace("/", "_") + ".git")
    diffs, exact, related, meta = {}, [], [], {}
    try:                                         # the view is an extra: the pages still render without it
        diffs = production_diffs(a.repo, allprs, gdir)
        exact, related, meta = same_change(a.repo, allprs, diffs, token, RULES)
    except Exception as e:                       # diffs already computed are kept (patch ids, carried reviews)
        exact, related, meta, sc_error = [], [], {}, str(e)[:200]
    for n, d in diffs.items():
        if n in by_number:
            by_number[n]["production_patch_id"] = d.get("patch_id")
            by_number[n]["production_files"] = d.get("files")
            by_number[n]["production_patch_id_context"] = d.get("patch_id_context")
            by_number[n]["production_changed_lines"] = d.get("changed_lines")
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
    carried_reviews = carry_reviews(a.repo, rows, diffs, gdir) if diffs else 0
    for r in rows:                               # internal: carry_reviews' input, never published
        r.pop("peeryard_prior", None)
    claims = load_claims()
    for r in rows:
        c = claims.get(r["number"])
        r["claimed"] = {"by": c["by"], "kind": c.get("kind"), "expires_at": c["expires_at"]} if c else None
    sc_secs = round(time.time() - t0)
    uncompared = sorted(n for n, d in diffs.items() if d.get("error"))
    review = rank_review(rows)
    maint = rank_maintainer(rows)
    stale_days = RULES.get("stale_days", 90)
    stale = sorted([r for r in rows if r["days_at_head"] > stale_days], key=lambda r: -r["days_at_head"])
    wip = [r for r in rows if is_wip(r) and r["days_at_head"] <= stale_days]
    rebase = sorted([r for r in rows if needs_rebase(r) and r["days_at_head"] <= stale_days and not is_wip(r)
                     and r["reviews_at_head"] == 0 and not r["peeryard_review"]], key=lambda r: (r["tier"][0], -r["days_at_head"]))
    carried = [c for c in carried_patches() if c["repo"] == a.repo]
    carried.sort(key=lambda c: (-len(c["needed_by"]), c["number"]))
    now = now_utc()
    generated, generated_at = now.strftime("%Y-%m-%d %H:%M UTC"), now.strftime("%Y-%m-%dT%H:%M:%SZ")
    os.makedirs(os.path.join(a.out, "maintainers"), exist_ok=True)
    os.makedirs(os.path.join(a.out, "outcomes"), exist_ok=True)
    reviewed = [r for r in rows if r["peeryard_review"]]
    cov = coverage(rows, review, rebase, wip, stale_days)
    try:
        outs = outcomes(a.repo, token)
    except Exception as e:                       # an extra: the pages still render without it
        outs = []
        print(f"outcomes not computed: {str(e)[:200]}", file=sys.stderr)
    out_counts = {k: sum(1 for o in outs if o["outcome"] == k) for k in ("merged", "closed as recommended", "closed")}
    same_secs = same_change_sections(exact, related, meta, sc_error, uncompared)

    cols = ["pull request", "why here"]
    index = page("Ergo node pull requests that need a review", [
        ("Coverage", coverage_text(cov, out_counts), [], []),
        ("Needs a review", "No review at the current head, ranked by risk tier (consensus, sync and state first), then by how long "
         "the head has waited, then by size. An agent reviews one with peeryard's <code>AGENTS.md</code>; a person with "
         "the same steps. Pick from the top.", [(pr_cell(r), why_cell(r)) for r in review], cols),
        *same_secs,
        ("Reviewed with peeryard at this head", "Shown so nobody does the same review twice; the link is the review. A "
         "pull-request review or comment counts when it carries the <code>&lt;!-- peeryard {…} --&gt;</code> marker "
         "(<code>queue/mark.py</code>) or the credit-line words \"using peeryard\". A review made at an earlier head stands "
         "while the production diff (<code>src/main</code>, changed lines) keeps the same <code>git patch-id</code>: a rebase "
         "or a tests-only push does not re-open it; a production change does.",
         [(pr_cell(r), reviewed_cell(r)) for r in reviewed], ["pull request", "review"]),
        ("Needs a rebase before a review", "GitHub reports conflicts with the base branch, so the author has to act before a "
         "maintainer could merge; not offered for review by default. The diff against the pull request's own merge base is "
         "still readable, so a reviewer who wants one of these may still take it. Read from GitHub's mergeable state; nothing "
         "is posted; a row leaves when the author rebases.",
         [(pr_cell(r), f"<span class=why>tier {r['tier'][0]} ({html.escape(r['tier'][1])}); {r['days_at_head']} days at this head; CI {r['ci']}</span>") for r in rebase], cols),
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
    outcomes_page = page("Outcomes of peeryard reviews", [
        ("What became of the pull requests reviewed with peeryard", "Closed pull requests that had a peeryard review: merged; "
         "closed as the last review's <code>Recommended:</code> line asked (close, withdraw, drop); or closed for another reason. "
         f"Today: {out_counts['merged']} merged, {out_counts['closed as recommended']} closed as recommended, {out_counts['closed']} closed otherwise. "
         "A review's effect is not a merge count: a duplicate closed on evidence is a review that worked. Latest closed first.",
         [(f"<a href='{o['url']}'>#{o['number']}</a> {html.escape(o['title'])}<br><small>{html.escape(o['author'])}, "
           f"{o['reviews']} peeryard review(s) from {o['first_review']}</small>",
           f"{o['closed_at']}<br><b>{o['outcome']}</b>",
           f"<span class=why>{html.escape(o['recommended'] or 'no Recommended: line')}</span><br><a href='{o['review']}'>review</a>") for o in outs],
         ["pull request", "closed", "the last review said"]),
    ], generated, a.repo, path_prefix="../")
    with open(os.path.join(a.out, "outcomes", "index.html"), "w") as f:
        f.write(outcomes_page)
    with open(os.path.join(a.out, "index.html"), "w") as f:
        f.write(index)
    with open(os.path.join(a.out, "maintainers", "index.html"), "w") as f:
        f.write(maint_page)
    with open(os.path.join(a.out, "queue.json"), "w") as f:
        json.dump({"schema_version": SCHEMA_VERSION, "generated": generated, "generated_at": generated_at, "repo": a.repo, "needs_review": [r["number"] for r in review],
                   "needs_maintainer": [r["number"] for r in maint], "needs_rebase": [r["number"] for r in rebase], "carried": carried,
                   "coverage": cov, "outcomes": outs, "claims": [dict(c, pr=int(c["pr"])) for c in claims.values()],
                   "same_change": exact, "same_issue": related, "same_change_error": sc_error,
                   "same_change_uncompared": uncompared, "min_changed_lines": RULES.get("same_change", {}).get("min_changed_lines", 1),
                   "open_prs": len(allprs), "rows": rows}, f, indent=1, default=str)
    dates = write_history(a.out, prior, snapshot(generated_at, a.repo, allprs, rows, exact, related, sc_error, uncompared, cov, out_counts))
    print(f"{len(rows)} open PRs: {len(review)} need a review, {len(rebase)} need a rebase first, {len(maint)} need a maintainer, {len(reviewed)} reviewed with peeryard "
          f"({carried_reviews} carried from an earlier head; kinds {cov['peeryard_kinds']}), outcomes {out_counts}, {len(claims)} claim(s), "
          f"{len(carried)} carried; same change: {len(exact)} group(s), same issue: {len(related)} group(s) ({sc_secs} s"
          + (f", not computed: {sc_error}" if sc_error else "") + f"); history: {len(dates)} day(s); written to {a.out}")


if __name__ == "__main__":
    main()
