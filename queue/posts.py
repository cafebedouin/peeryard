"""posts.py: peeryard posts on a pull request (the structured marker, the credit-line phrase, the legacy credit line by
a reviewers.json login), whether a review or post was made at the current head, and what became of the pull requests
peeryard reviewed (outcomes). Part of queue/build.py (see its docstring)."""
import json, os, re, sys

from ghapi import api, parse_ts, search_numbers

HERE = os.path.dirname(os.path.abspath(__file__))


MARKER_RE = re.compile(r"<!--\s*peeryard\s+(\{.*?\})\s*-->", re.S)
PHRASES = ("using peeryard", "using forkbench")
NON_REVIEW_KINDS = {"reply", "pr-description", "pr"}    # marker kinds that are posts made with peeryard but not reviews of the head
CREDIT_RE = re.compile(r"^\s*(Review carried out by|Prepared (with|by)|Carried out by|Reply by)", re.I)


def load_reviewers():
    """queue/reviewers.json: logins whose credit-line posts made before the marker existed count as peeryard reviews."""
    path = os.path.join(HERE, "reviewers.json")
    if not os.path.isfile(path):
        return {"logins": [], "until": "1970-01-01T00:00:00Z"}
    with open(path) as f:
        j = json.load(f)
    return {"logins": set(j.get("logins") or []), "until": j.get("legacy_credit_line_until", "1970-01-01T00:00:00Z")}


def peeryard_posts(reviews, comments):
    """The peeryard posts on one pull request, oldest first: {url, at, source, kind, head, prod_patch_id, commit_id}.
    source is "marker" (the structured comment), "phrase" (the credit-line words) or "legacy" (a credit-line opening by a
    listed login, before reviewers.json's date). A pull-request review also carries commit_id, the head it was made on."""
    legacy = load_reviewers()
    out = []
    for kind, items in (("review", reviews), ("comment", comments)):
        for c in items:
            at = c.get("submitted_at") if kind == "review" else c.get("created_at")
            body = c.get("body") or ""
            if not at or not body:
                continue
            rec = {"url": c["html_url"], "at": parse_ts(at), "login": c["user"]["login"], "source": None, "kind": None,
                   "head": None, "prod_patch_id": None, "commit_id": c.get("commit_id") if kind == "review" else None}
            m = MARKER_RE.search(body)
            if m:
                try:
                    j = json.loads(m.group(1))
                    rec.update({"source": "marker", "kind": j.get("kind"), "head": j.get("head"), "prod_patch_id": j.get("prod_patch_id")})
                except ValueError:
                    pass
            if not rec["source"] and any(ph in body.lower() for ph in PHRASES):
                rec["source"] = "phrase"
            if not rec["source"] and rec["login"] in legacy["logins"] and at <= legacy["until"]:
                first = next((l for l in body.splitlines() if l.strip()), "")
                if CREDIT_RE.match(first):
                    rec["source"] = "legacy"
            if rec["source"] and not rec["kind"]:          # no marker: the report form says whether anything was executed
                rec["kind"] = "executed" if re.search(r"^\**Executed\b|\(executed\)|^\**Reproduced\b", body, re.M) else "read"
            if rec["source"]:
                m = re.search(r"Recommended:\s*\**\s*(.+)", body)
                rec["recommended"] = re.sub(r"\s+", " ", m.group(1)).strip()[:200] if m else None
                out.append(rec)
    out.sort(key=lambda r: r["at"])
    return out


def peeryard_field(p):
    return {"url": p["url"], "at": p["at"].isoformat(), "source": p["source"], "kind": p["kind"], "by": p["login"],
            "head": (p["head"] or p["commit_id"] or None), "prod_patch_id": p["prod_patch_id"], "carried_from": None,
            "recommended": p.get("recommended")}


def outcomes(repo, token):
    """Closed pull requests with a peeryard review (found by the phrase or marker in comments, and by the reviewers.json
    logins as reviewer or commenter for the backfill): merged, closed as the last review recommended (its Recommended:
    line begins with close, withdraw or drop), or closed otherwise. One row per pull request, latest closed first."""
    legacy = load_reviewers()
    queries = [f'repo:{repo} is:pr is:closed "using peeryard" in:comments', f'repo:{repo} is:pr is:closed "<!-- peeryard" in:comments']
    for login in sorted(legacy["logins"]):
        queries += [f"repo:{repo} is:pr is:closed reviewed-by:{login}", f"repo:{repo} is:pr is:closed commenter:{login}"]
    nums = set()
    for q in queries:
        nums.update(search_numbers(q, token))
    rows = []
    for n in sorted(nums):
        try:
            full = api(f"/repos/{repo}/pulls/{n}", token=token)
            reviews = api(f"/repos/{repo}/pulls/{n}/reviews", {"per_page": 100}, token, paginate=True)
            comments = api(f"/repos/{repo}/issues/{n}/comments", {"per_page": 100}, token, paginate=True)
        except Exception:
            continue
        posts = [c for c in peeryard_posts(reviews, comments) if c["login"] != full["user"]["login"] and c["kind"] not in NON_REVIEW_KINDS]
        if not posts:
            continue
        last = posts[-1]
        rec = (last.get("recommended") or "")
        if full.get("merged_at"):
            outcome = "merged"
        elif re.match(r"(?i)\s*(close|withdraw|drop)", rec):
            outcome = "closed as recommended"
        else:
            outcome = "closed"
        rows.append({"number": n, "title": full["title"], "author": full["user"]["login"], "url": full["html_url"],
                     "closed_at": (full.get("merged_at") or full.get("closed_at") or "")[:10], "outcome": outcome,
                     "recommended": rec or None, "review": last["url"], "reviews": len(posts), "first_review": posts[0]["at"].isoformat()[:10]})
    rows.sort(key=lambda r: r["closed_at"], reverse=True)
    return rows


def head_push_time(repo, n, head_sha, head_commit, token):
    """(when the head commit reached the pull request, how that is known). The REST API records a push time only for a
    force push (the timeline's head_ref_force_pushed event, whose commit_id is the new head; its `committed` events carry
    the commit's own dates, not the push). Otherwise the head's earliest check suite stands in for it (GitHub creates
    the suites on the push). With neither, the head commit's committer date, which can be earlier than the push: a
    commit written before a review and pushed after it then makes that review look as if it were made at this head."""
    try:
        tl = api(f"/repos/{repo}/issues/{n}/timeline", {"per_page": 100}, token, paginate=True)
        fp = [parse_ts(e["created_at"]) for e in tl
              if e.get("event") == "head_ref_force_pushed" and e.get("commit_id") == head_sha and e.get("created_at")]
        if fp:
            return max(fp), "force-push"
    except Exception as e:
        print(f"warning: #{n}: timeline not read ({str(e)[:120]}); push time from the check suites or the commit", file=sys.stderr)
    try:
        suites, page = [], 1
        while True:                    # an object ({total_count, check_suites}), so api(paginate=True) cannot page it
            got = api(f"/repos/{repo}/commits/{head_sha}/check-suites", {"per_page": 100, "page": page}, token).get("check_suites", [])
            suites += got
            if len(got) < 100 or page >= 10:
                break
            page += 1
        cs = [parse_ts(s["created_at"]) for s in suites if s.get("created_at")]
        if cs:
            return min(cs), "check-suite"
    except Exception as e:
        print(f"warning: #{n}: check suites not read ({str(e)[:120]}); push time from the commit", file=sys.stderr)
    return parse_ts(head_commit["commit"]["committer"]["date"]), "committer-date"


def review_at_head(r, head_sha, head_at):
    """A GitHub review was made at the current head: by its commit_id (the head it was submitted on) when GitHub gives
    one, else by its submission time against the head's push time. A pending (unsubmitted) review never counts."""
    if r.get("state") == "PENDING" or not r.get("submitted_at"):
        return False
    if r.get("commit_id"):
        return r["commit_id"] == head_sha
    return parse_ts(r["submitted_at"]) > head_at


def post_at_head(p, head_sha, head_at):
    """A peeryard post (peeryard_posts) was made at the current head: by the heads it names (a review's commit_id and its
    marker's head; when both are given, both must be the current head, since a review submitted on one head can carry
    a marker for another, and peeryard_field reports the marker's), else, for a comment with no head named, by its
    time against the head's push time."""
    heads = [h for h in (p.get("commit_id"), p.get("head")) if h]
    if heads:
        return all(len(h) >= 7 and head_sha.startswith(h) for h in heads)
    return p["at"] > head_at
