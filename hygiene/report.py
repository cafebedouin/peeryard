#!/usr/bin/env python3
"""report.py: the pull-request hygiene report, one row per open pull request, from public GitHub data and git.

The maintainers of ergoplatform/ergo ask contributors to target the current release branch, to tie each pull request to
an issue, and not to open a second pull request for an issue that already has one; they also weigh how a change will
merge into the two long-running lines (sub-blocks, the 6.1 RocksDB line). This report applies those asks to every open
pull request at once, mechanically: what each one targets, which issue it is tied to, which other open pull requests are
tied to the same issue, whether its commits are already in a live branch, how many new conflicts it brings into each
line, and its CI state and review decision. The branch roles are data (hygiene/branches.json). It judges nothing: a row
is a fact about the pull request, not a ruling on it.

    python3 hygiene/report.py [--config hygiene/branches.json] [--out site/hygiene] [--git-cache DIR] [--limit N]

Standard library and git (2.38 or later, for merge-tree --write-tree). A token is needed for GitHub's GraphQL API:
GITHUB_TOKEN or GH_TOKEN, else `gh auth token`. Reads: the open pull requests with their closing-issue references,
review decision, CI rollup and mergeability (GraphQL, 50 per page), the issue-or-pull-request kind of each number a
description says it addresses, and a full bare clone (--git-cache; kept between local runs) with every branch and
refs/pull/N/head. Writes <out>/hygiene.md and <out>/hygiene.json. Fields and limits: hygiene/README.md.
"""
import argparse, datetime as dt, json, os, re, subprocess, sys, tempfile, time, urllib.error, urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(ROOT, "queue"))
import build as queue  # noqa: E402  (queue/build.py: the clone-and-fetch, git and issue-reference helpers)

GRAPHQL = "https://api.github.com/graphql"
SCHEMA_VERSION = 1


# ---- GitHub ---------------------------------------------------------------------------------------------------------

def token_from_env():
    t = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
    if t:
        return t
    try:
        return subprocess.run(["gh", "auth", "token"], capture_output=True, text=True, check=True).stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        sys.exit("report.py: GitHub's GraphQL API needs a token: set GITHUB_TOKEN (or GH_TOKEN), or log in with gh")


def graphql(query, variables, token):
    body = json.dumps({"query": query, "variables": variables}).encode()
    for attempt in range(5):
        req = urllib.request.Request(GRAPHQL, data=body, headers={"Authorization": f"Bearer {token}",
                                                                  "User-Agent": "peeryard-hygiene"})
        try:
            with urllib.request.urlopen(req, timeout=90) as r:
                data = json.loads(r.read().decode())
        except urllib.error.HTTPError as e:
            if e.code in (403, 429, 502, 503, 504) and attempt < 4:
                time.sleep(15 * (attempt + 1)); continue
            raise
        if data.get("errors") and not data.get("data"):
            if attempt < 4 and any("timeout" in (e.get("message") or "").lower() for e in data["errors"]):
                time.sleep(10); continue
            raise RuntimeError(f"graphql: {data['errors'][0].get('message')}")
        return data["data"]
    raise RuntimeError("graphql: retries exhausted")


PR_QUERY = """
query($owner:String!, $name:String!, $after:String) {
  repository(owner:$owner, name:$name) {
    pullRequests(states:OPEN, first:50, after:$after, orderBy:{field:CREATED_AT, direction:ASC}) {
      pageInfo { hasNextPage endCursor }
      nodes {
        number title url isDraft createdAt updatedAt body
        author { login }
        baseRefName baseRefOid headRefName headRefOid
        headRepository { nameWithOwner }
        reviewDecision mergeable
        closingIssuesReferences(first:25) { nodes { number title state } }
        commits(last:1) { nodes { commit { statusCheckRollup { state } } } }
      }
    }
  }
}"""


def open_prs(repo, token):
    owner, name = repo.split("/")
    out, after = [], None
    while True:
        d = graphql(PR_QUERY, {"owner": owner, "name": name, "after": after}, token)["repository"]["pullRequests"]
        out.extend(d["nodes"])
        if not d["pageInfo"]["hasNextPage"]:
            return out
        after = d["pageInfo"]["endCursor"]


def kinds_of(repo, numbers, token):
    """{n: {"kind": "issue"|"pr"|"missing", "title", "state"}} for each number, 100 per query."""
    owner, name = repo.split("/")
    out, numbers = {}, sorted(numbers)
    for i in range(0, len(numbers), 100):
        chunk = numbers[i:i + 100]
        fields = " ".join(f"n{n}: issueOrPullRequest(number:{n}) {{ __typename ... on Issue {{ title state }} "
                          f"... on PullRequest {{ title state }} }}" for n in chunk)
        q = f"query($owner:String!, $name:String!) {{ repository(owner:$owner, name:$name) {{ {fields} }} }}"
        body = json.dumps({"query": q, "variables": {"owner": owner, "name": name}}).encode()
        req = urllib.request.Request(GRAPHQL, data=body, headers={"Authorization": f"Bearer {token}",
                                                                  "User-Agent": "peeryard-hygiene"})
        with urllib.request.urlopen(req, timeout=90) as r:      # a number that is neither comes back null with an error
            data = json.loads(r.read().decode()).get("data") or {}
        repo_d = data.get("repository") or {}
        for n in chunk:
            v = repo_d.get(f"n{n}")
            out[n] = ({"kind": "issue" if v["__typename"] == "Issue" else "pr", "title": v.get("title", ""),
                       "state": (v.get("state") or "").lower()} if v else {"kind": "missing", "title": "", "state": ""})
    return out


# ---- roles and issues -----------------------------------------------------------------------------------------------

def role_of(base, cfg):
    for role, branches in cfg["roles"].items():
        if base in branches:
            return role
    return "other"


def is_release_head(repo, p, cfg):
    """A pull request from a release branch of the repository itself (v6.0.10 into master): it lists the issues of the
    whole release, so it is left out of the duplicate clusters."""
    return ((p.get("headRepository") or {}).get("nameWithOwner") == repo
            and re.match(cfg.get("release_head", r"^v[0-9]"), p.get("headRefName") or "") is not None)


def issue_links(repo, prs, token):
    """Per pull request: formal closing references (GitHub's closingIssuesReferences) and text references (a number the
    title or description says it addresses, by queue/build.py's issue_refs rule, that GitHub says is an issue, not a
    pull request). Returns ({n: {"formal": [...], "text": [...], "kind": ...}}, {issue: {"title", "state"}})."""
    open_numbers = {p["number"] for p in prs}
    formal, cand, info = {}, {}, {}
    for p in prs:
        n = p["number"]
        formal[n] = sorted({i["number"] for i in p["closingIssuesReferences"]["nodes"]})
        for i in p["closingIssuesReferences"]["nodes"]:
            info[i["number"]] = {"title": i["title"], "state": i["state"].lower()}
        refs = queue.issue_refs(repo, {"number": n, "title": p["title"], "body": p.get("body") or ""})
        cand[n] = sorted(refs - set(formal[n]) - open_numbers)         # an open pull request's number is not an issue
    unknown = {i for v in cand.values() for i in v} - set(info)
    kinds = kinds_of(repo, unknown, token) if unknown else {}
    for i, k in kinds.items():
        if k["kind"] == "issue":
            info[i] = {"title": k["title"], "state": k["state"]}
    out = {}
    for p in prs:
        n = p["number"]
        text = [i for i in cand[n] if i in info and (i not in kinds or kinds[i]["kind"] == "issue")]
        out[n] = {"formal": formal[n], "text": text, "kind": "formal" if formal[n] else ("text" if text else "none")}
    return out, info


def clusters(repo, prs, links, cfg):
    """Issues with two or more open pull requests tied to them (formal or text), release-branch pull requests left out."""
    by_issue = {}
    for p in prs:
        if is_release_head(repo, p, cfg):
            continue
        n, l = p["number"], links[p["number"]]
        for i in l["formal"]:
            by_issue.setdefault(i, {})[n] = "formal"
        for i in l["text"]:
            by_issue.setdefault(i, {}).setdefault(n, "text")
    return {i: dict(sorted(v.items())) for i, v in sorted(by_issue.items()) if len(v) > 1}


# ---- git: already landed, new conflicts -----------------------------------------------------------------------------

def run_git(gdir, *args, stdin=None, env=None, ok=(0,)):
    r = subprocess.run(["git", "--git-dir", gdir, *args], input=stdin, capture_output=True, text=True,
                       env={**os.environ, **(env or {})})
    if r.returncode not in ok:
        raise RuntimeError(f"git {' '.join(args[:3])}: {r.stderr.strip()[:300]}")
    return r


def has_ref(gdir, ref):
    return run_git(gdir, "rev-parse", "-q", "--verify", ref + "^{commit}", ok=(0, 1)).returncode == 0


def patch_ids(gdir, revs):
    """{commit: patch-id} (git patch-id --stable) of every non-merge commit reachable from revs. One git log -p, one
    patch-id; a commit with an empty diff has no id."""
    log = subprocess.Popen(["git", "--git-dir", gdir, "log", "-p", "--no-merges", "--no-renames", "--no-color",
                            "--no-ext-diff", "--format=commit %H", *revs], stdout=subprocess.PIPE)
    pid = subprocess.run(["git", "--git-dir", gdir, "patch-id", "--stable"], stdin=log.stdout, capture_output=True, text=True)
    log.stdout.close()
    if log.wait() or pid.returncode:
        raise RuntimeError(f"patch-id: {pid.stderr.strip()[:300]}")
    return {c: p for p, c in (line.split() for line in pid.stdout.splitlines())}


def diff_patch_id(gdir, a, b):
    patch = run_git(gdir, "diff", "--no-renames", "--no-color", "--no-ext-diff", a, b).stdout
    if not patch:
        return None
    return (run_git(gdir, "patch-id", "--stable", stdin=patch).stdout.split() or [None])[0]


def pr_range(gdir, p):
    """(merge base, head) of a pull request as GitHub shows it: the base branch as fetched (its recorded oid if the branch
    is gone) and refs/pull/N/head."""
    head = f"refs/pull/{p['number']}/head"
    if not has_ref(gdir, head):
        raise RuntimeError("head not fetched")
    head = run_git(gdir, "rev-parse", head).stdout.strip()
    base = f"refs/heads/{p['baseRefName']}"
    if not has_ref(gdir, base):
        base = p["baseRefOid"]
    return run_git(gdir, "merge-base", base, head).stdout.split()[0], head


def landed(gdir, ranges, targets):
    """Per pull request: how many of its commits (merge base..head, merges left out) have a commit with the same
    patch-id, or the same commit, in each target branch; and the targets that hold one commit whose patch-id equals the
    whole pull request's diff (a squash merge of exactly this change)."""
    present = [t for t in targets if has_ref(gdir, f"refs/heads/{t}")]
    revs = [f"refs/heads/{t}" for t in present] + sorted({h for _, h in ranges.values()})
    pid_of = patch_ids(gdir, revs)
    where = {}                                                        # patch-id -> set of targets holding it
    for t in present:
        for c in run_git(gdir, "rev-list", "--no-merges", f"refs/heads/{t}").stdout.split():
            if c in pid_of:
                where.setdefault(pid_of[c], set()).add(t)
    out = {}
    for n, (mb, head) in ranges.items():
        commits = run_git(gdir, "rev-list", "--no-merges", f"{mb}..{head}").stdout.split()
        per = {t: 0 for t in present}
        counted = 0
        for c in commits:
            p = pid_of.get(c)
            if p is None:
                continue                                              # an empty commit: nothing to find
            counted += 1
            for t in where.get(p, ()):
                per[t] += 1
        whole = diff_patch_id(gdir, mb, head) if commits else None
        squash = sorted(where.get(whole, ())) if whole else []
        all_in = [t for t in present if counted and per[t] == counted]
        some_in = [t for t in present if 0 < per[t] < counted]
        status = ("empty" if not counted else "all" if all_in or squash else "some" if some_in else "none")
        out[n] = {"commits": len(commits), "with_diff": counted, "per_target": per, "all_in": all_in,
                  "some_in": some_in, "squash_in": squash, "status": status}
    return out, [t for t in targets if t not in present]


MIN_LINE = 12          # an added line shorter than this once stripped ("}", "} else {", an import) is too common to count


class Blobs:
    """File contents by <rev>:<path>, through one git cat-file --batch process; a missing file reads as empty."""

    def __init__(self, gdir):
        self.p = subprocess.Popen(["git", "--git-dir", gdir, "cat-file", "--batch"], stdin=subprocess.PIPE,
                                  stdout=subprocess.PIPE)
        self.cache = {}

    def lines(self, rev, path):
        key = (rev, path)
        if key not in self.cache:
            if len(self.cache) > 4000:                  # bounded: a large pull request reads hundreds of files
                self.cache.clear()
            self.p.stdin.write(f"{rev}:{path}\n".encode()); self.p.stdin.flush()
            header = self.p.stdout.readline().decode().split()
            if len(header) == 3 and header[1] == "blob":
                body = self.p.stdout.read(int(header[2])); self.p.stdout.read(1)
                self.cache[key] = {l.strip() for l in body.decode(errors="replace").splitlines()}
            else:
                if len(header) == 3:                    # a tree or other object at that path: skip its content
                    self.p.stdout.read(int(header[2]) + 1)
                self.cache[key] = set()
        return self.cache[key]

    def close(self):
        self.p.stdin.close(); self.p.wait()


def content_present(gdir, ranges, targets):
    """Per pull request: of the lines its diff adds (merge base..head, at least MIN_LINE characters once stripped) that
    are not already in the same file at its merge base, how many are in that file on each target branch. A second
    measure beside the patch-ids: it still sees a change that landed edited or squashed with others, at the same path."""
    present = [t for t in targets if has_ref(gdir, f"refs/heads/{t}")]
    blobs, out = Blobs(gdir), {}
    try:
        for n, (mb, head) in ranges.items():
            added, f = {}, None
            for line in run_git(gdir, "diff", "-U0", "--no-renames", "--no-color", "--no-ext-diff", mb, head).stdout.splitlines():
                if line.startswith("+++ "):
                    f = line[6:] if line.startswith("+++ b/") else None
                elif line.startswith("+") and f and len(line[1:].strip()) >= MIN_LINE:
                    added.setdefault(f, set()).add(line[1:].strip())
            new = {f: ls - blobs.lines(mb, f) for f, ls in added.items()}
            total = sum(len(ls) for ls in new.values())
            out[n] = {"lines": total, "present": {t: sum(len(ls & blobs.lines(f"refs/heads/{t}", f)) for f, ls in new.items())
                                                  for t in present}}
    finally:
        blobs.close()
    return out


def merge_conflicts(gdir, ours, theirs, objdir):
    """The files git merge-tree --write-tree reports conflicted when merging theirs into ours; the trees it writes go to
    a scratch object directory, not into the clone."""
    r = run_git(gdir, "merge-tree", "--write-tree", "--name-only", "--no-messages", ours, theirs, ok=(0, 1),
                env={"GIT_OBJECT_DIRECTORY": objdir,
                     "GIT_ALTERNATE_OBJECT_DIRECTORIES": os.path.join(gdir, "objects")})
    return set() if r.returncode == 0 else {l for l in r.stdout.splitlines()[1:] if l.strip()}


def new_conflicts(gdir, ranges, lines):
    """Per pull request and line: files conflicted when its head is merged into the line, minus the files its merge base
    already conflicts on against that line (those are the line's divergence, not the pull request's)."""
    present = [l for l in lines if has_ref(gdir, f"refs/heads/{l}")]
    out, base_cache = {}, {}
    with tempfile.TemporaryDirectory(prefix="hygiene-objs-") as objdir:
        for n, (mb, head) in ranges.items():
            row = {}
            for l in present:
                ref = f"refs/heads/{l}"
                try:
                    if (mb, l) not in base_cache:
                        base_cache[(mb, l)] = merge_conflicts(gdir, ref, mb, objdir)
                    at_head = merge_conflicts(gdir, ref, head, objdir)
                    new = sorted(at_head - base_cache[(mb, l)])
                    row[l] = {"new": new, "count": len(new), "at_head": len(at_head),
                              "at_merge_base": len(base_cache[(mb, l)])}
                except RuntimeError as e:
                    row[l] = {"error": str(e)[:200]}
            out[n] = row
    return out, [l for l in lines if l not in present]


# ---- the report -----------------------------------------------------------------------------------------------------

def ci_of(p):
    nodes = p["commits"]["nodes"]
    roll = (nodes[0]["commit"].get("statusCheckRollup") or {}) if nodes else {}
    return {"SUCCESS": "green", "FAILURE": "red", "ERROR": "red", "PENDING": "pending",
            "EXPECTED": "pending"}.get(roll.get("state"), "none")


def build_rows(repo, prs, cfg, links, issue_info, clus, land, conf):
    member = {}
    for i, ns in clus.items():
        for n in ns:
            member.setdefault(n, []).append(i)
    rows = []
    for p in prs:
        n = p["number"]
        rows.append({
            "number": n, "title": p["title"], "url": p["url"], "author": (p.get("author") or {}).get("login") or "ghost",
            "created": p["createdAt"], "updated": p["updatedAt"], "draft": p["isDraft"],
            "base": p["baseRefName"], "base_role": role_of(p["baseRefName"], cfg),
            "head": p["headRefOid"], "release_head": is_release_head(repo, p, cfg),
            "issue": links[n],
            "clusters": [{"issue": i, "others": [m for m in clus[i] if m != n], "link": clus[i][n]} for i in member.get(n, [])],
            "landed": land.get(n), "conflicts": conf.get(n),
            "ci": ci_of(p), "review_decision": (p.get("reviewDecision") or "none").lower(),
            "mergeable": (p.get("mergeable") or "unknown").lower(),
        })
    return rows


def md(s):
    return str(s).replace("|", "\\|").replace("\n", " ").strip()


def content_best(l):
    """(present, lines, "branch, branch") for the branches holding the most of the pull request's new added lines (all of
    them on a tie); None if it adds none."""
    c = (l or {}).get("content") or {}
    if not c.get("lines") or not c.get("present"):
        return None
    k = max(c["present"].values())
    return k, c["lines"], ", ".join(t for t, v in c["present"].items() if v == k)


CONTENT_SHOWN = 0.5    # the landed cell names the content measure when at least this share of added lines is found


def landed_cell(l):
    if not l:
        return "n/a"
    if l.get("error"):
        return "error"
    if l["status"] == "empty":
        return "no commits"
    parts = []
    best = content_best(l)
    if l["status"] != "all" and best and best[0] >= CONTENT_SHOWN * best[1]:
        parts.append(f"added lines {best[0]}/{best[1]}: {best[2]}")
    if l["all_in"]:
        parts.append(f"all {l['with_diff']}: " + ", ".join(l["all_in"]))
    if l["squash_in"] and not l["all_in"]:
        parts.append("as one squashed commit: " + ", ".join(l["squash_in"]))
    if l["some_in"]:
        counts = sorted({l["per_target"][t] for t in l["some_in"]}, reverse=True)
        parts.append("; ".join(f"{k}/{l['with_diff']}: " + ", ".join(t for t in l["some_in"] if l["per_target"][t] == k)
                               for k in counts))
    return " · ".join(p for p in parts if p) or "none"


def conflict_cell(c, lines):
    if not c:
        return "n/a"
    out = []
    for l in lines:
        v = c.get(l)
        out.append("?" if v is None or "error" in v else str(v["count"]))
    return " / ".join(out)


def issue_cell(i):
    if i["kind"] == "formal":
        return "formal " + ", ".join(f"#{x}" for x in i["formal"]) + ("; text " + ", ".join(f"#{x}" for x in i["text"]) if i["text"] else "")
    if i["kind"] == "text":
        return "text " + ", ".join(f"#{x}" for x in i["text"])
    return "none"


def merge_ready(r, cfg):
    c = r["conflicts"] or {}
    return (r["base_role"] == "current" and r["review_decision"] == "approved" and r["ci"] == "green" and not r["draft"]
            and all((c.get(l) or {}).get("count") == 0 for l in cfg["conflict_lines"]))


def render(repo, cfg, rows, clus, issue_info, meta):
    lines = cfg["conflict_lines"]
    roles = ["current", "full", "dead", "master", "line", "other"]
    by_role = {k: [r for r in rows if r["base_role"] == k] for k in roles}
    h = [f"# Pull-request hygiene: {repo}", "",
         f"Generated {meta['generated_at']} from public GitHub data and git by `hygiene/report.py`, in {meta['seconds']} s. "
         f"{len(rows)} open pull requests. Branch roles from `hygiene/branches.json` (as of {cfg.get('as_of', '?')}). "
         "Each row is a mechanical fact about a pull request, not a ruling on it; what each column means and its limits: "
         "`hygiene/README.md`.", ""]
    h += ["## Summary", "", "### Open pull requests by base role", "", "| role | branches | open pull requests |", "|---|---|---|"]
    for k in roles:
        branches = sorted({r["base"] for r in by_role[k]}, key=lambda b: (-sum(1 for r in by_role[k] if r["base"] == b), b))
        h.append(f"| {k} | " + ", ".join(f"{b} ({sum(1 for r in by_role[k] if r['base'] == b)})" for b in branches)
                 + f" | {len(by_role[k])} |")
    noissue = [r for r in rows if r["issue"]["kind"] == "none"]
    formal = sum(1 for r in rows if r["issue"]["kind"] == "formal")
    text = sum(1 for r in rows if r["issue"]["kind"] == "text")
    h += ["", "### Tie to an issue", "",
          f"{formal} with a formal closing reference, {text} with a text reference only, **{len(noissue)} with none**. "
          f"Without a formal closing reference: {len(rows) - formal}.", "",
          "| base role | pull requests with no issue |", "|---|---|"]
    for k in roles:
        ns = [r["number"] for r in noissue if r["base_role"] == k]
        if ns:
            h.append(f"| {k} ({len(ns)}) | " + ", ".join(f"#{n}" for n in ns) + " |")
    byn = {r["number"]: r for r in rows}
    h += ["", f"### Issues with more than one open pull request ({len(clus)})", "",
          "Every open pull request tied to the issue, formally (a closing reference GitHub records) or in text (the title "
          "or description says it addresses the issue). Pull requests from a release branch are left out.", "",
          "| issue | state | pull requests (base, author, opened, link) |", "|---|---|---|"]
    for i, ns in clus.items():
        info = issue_info.get(i, {})
        cells = "<br>".join(f"#{n} ({byn[n]['base']}, {md(byn[n]['author'])}, {byn[n]['created'][:10]}, {k})"
                            for n, k in ns.items())
        h.append(f"| #{i} {md(info.get('title', ''))[:70]} | {info.get('state', '?')} | {cells} |")
    dead = by_role["dead"]
    h += ["", f"### Pull requests on a dead branch ({len(dead)}): already landed?", "",
          "Landed: whether each commit of the pull request (merge base to head, merge commits left out) is in a live branch "
          "by `git patch-id --stable`, or the whole diff as one squashed commit. Added lines: of the lines the pull request "
          "adds that its merge base does not already have in that file, the most found in the same file on one branch (a "
          "change that landed edited still shows here).", "",
          "| pull request | opened | commits | landed (patch-id) | added lines found |", "|---|---|---|---|---|"]
    for r in sorted(dead, key=lambda r: r["number"]):
        l = r["landed"] or {}
        best = content_best(l)
        found = f"{best[0]}/{best[1]} ({best[2]})" if best and best[0] else (f"0/{best[1]}" if best else "n/a")
        h.append(f"| #{r['number']} {md(r['title'])[:60]} | {r['created'][:10]} | {l.get('with_diff', '?')} | "
                 f"{landed_cell(l)} | {found} |")
    def mostly(l):
        best = content_best(l)
        return bool(best) and best[0] >= CONTENT_SHOWN * best[1]
    already = [r for r in rows if r["base_role"] != "dead"
               and ((r["landed"] or {}).get("status") == "all" or mostly(r["landed"]))]
    h += ["", f"### Other pull requests already in a branch, wholly or mostly ({len(already)})", "",
          "Every commit found by patch-id (`all`), or at least half of the lines the pull request adds found in the same "
          "files on one branch (`added lines`): a change that may have landed in another form, or a branch that carries "
          "commits of other pull requests.", "",
          "| pull request | base | landed |", "|---|---|---|"]
    for r in already:
        h.append(f"| #{r['number']} {md(r['title'])[:60]} | {r['base']} | {landed_cell(r['landed'])} |")
    ready = [r for r in rows if merge_ready(r, cfg)]
    cur = ", ".join(cfg["roles"]["current"])
    h += ["", f"### Merge-ready for the current branch ({cur}): {len(ready)}", "",
          f"Base is the current branch, review decision approved, CI green, not a draft, and no new conflicts with "
          f"{' or '.join(lines)}.", ""]
    if ready:
        h += ["| pull request | author | updated | GitHub mergeable |", "|---|---|---|---|"]
        h += [f"| #{r['number']} {md(r['title'])[:70]} | {md(r['author'])} | {r['updated'][:10]} | {r['mergeable']} |" for r in ready]
    else:
        h.append("None today.")
    near = [r for r in by_role["current"] if r not in ready]
    if near:
        h += ["", "Other pull requests on the current branch, with what keeps each off the list:", ""]
        for r in near:
            why = []
            if r["review_decision"] != "approved":
                why.append(f"review {r['review_decision']}")
            if r["ci"] != "green":
                why.append(f"CI {r['ci']}")
            if r["draft"]:
                why.append("draft")
            c = r["conflicts"] or {}
            for l in lines:
                v = c.get(l) or {}
                if v.get("count") != 0:
                    why.append(f"{v['count']} new conflict(s) with {l}" if "count" in v else f"conflicts with {l} not computed")
            h.append(f"- #{r['number']} {md(r['title'])[:70]}: {', '.join(why)}")
    if meta.get("missing_branches"):
        h += ["", "Branches named in the config but absent upstream (not compared): " + ", ".join(meta["missing_branches"])]
    if meta.get("errors"):
        h += ["", "Pull requests whose git columns could not be computed: "
              + "; ".join(f"#{n} ({md(e)})" for n, e in sorted(meta["errors"].items()))]
    h += ["", "## All open pull requests", "",
          f"Conflicts: new conflicted files when the head is merged into {' / '.join(lines)}, beyond those its merge base "
          "already has. Landed: commits found in a branch by patch-id.", "",
          "| # | title | author | created | updated | base (role) | issue | same issue as | landed | new conflicts "
          + " / ".join(lines) + " | CI | review | draft |",
          "|---|---|---|---|---|---|---|---|---|---|---|---|---|"]
    for r in rows:
        same = "; ".join(f"#{c['issue']}: " + ", ".join(f"#{m}" for m in c["others"]) for c in r["clusters"]) or ""
        h.append(f"| {r['number']} | {md(r['title'])[:70]} | {md(r['author'])} | {r['created'][:10]} | {r['updated'][:10]} | "
                 f"{r['base']} ({r['base_role']}) | {issue_cell(r['issue'])} | {same} | {landed_cell(r['landed'])} | "
                 f"{conflict_cell(r['conflicts'], lines)} | {r['ci']} | {r['review_decision']} | {'yes' if r['draft'] else ''} |")
    return "\n".join(h) + "\n"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", default=os.path.join(HERE, "branches.json"))
    ap.add_argument("--out", default=os.path.join(ROOT, "site", "hygiene"))
    ap.add_argument("--git-cache", default=os.path.join(os.path.expanduser("~"), ".cache", "peeryard", "hygiene"),
                    help="where the full bare clone lives (kept between runs; patch-ids and merge-tree read blobs)")
    ap.add_argument("--limit", type=int, default=0, help="only the first N open pull requests (for a local test)")
    a = ap.parse_args()
    with open(a.config) as f:
        cfg = json.load(f)
    repo = cfg["repo"]
    token = token_from_env()
    t0 = time.time()
    timing = {}
    prs = open_prs(repo, token)
    prs = prs[: a.limit or None]
    timing["github_prs"] = round(time.time() - t0)
    t = time.time()
    links, issue_info = issue_links(repo, prs, token)
    clus = clusters(repo, prs, links, cfg)
    timing["github_issues"] = round(time.time() - t)
    t = time.time()
    gdir = os.path.join(a.git_cache, repo.replace("/", "_") + ".git")
    queue.fetch_pr_heads(repo, [p["number"] for p in prs], gdir, blobless=False)
    timing["git_fetch"] = round(time.time() - t)
    ranges, errors = {}, {}
    for p in prs:
        try:
            ranges[p["number"]] = pr_range(gdir, p)
        except RuntimeError as e:
            errors[p["number"]] = str(e)[:200]
    t = time.time()
    land, missing_t = landed(gdir, ranges, cfg["landed_targets"])
    for n, c in content_present(gdir, ranges, cfg["landed_targets"]).items():
        land[n]["content"] = c
    timing["landed"] = round(time.time() - t)
    t = time.time()
    conf, missing_l = new_conflicts(gdir, ranges, cfg["conflict_lines"])
    timing["conflicts"] = round(time.time() - t)
    for n, e in errors.items():
        land[n] = {"error": e}
    rows = build_rows(repo, prs, cfg, links, issue_info, clus, land, conf)
    meta = {"generated_at": dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "seconds": round(time.time() - t0), "timing": timing, "errors": errors,
            "missing_branches": sorted(set(missing_t) | set(missing_l))}
    os.makedirs(a.out, exist_ok=True)
    with open(os.path.join(a.out, "hygiene.md"), "w") as f:
        f.write(render(repo, cfg, rows, clus, issue_info, meta))
    ready = [r["number"] for r in rows if merge_ready(r, cfg)]
    with open(os.path.join(a.out, "hygiene.json"), "w") as f:
        json.dump({"schema_version": SCHEMA_VERSION, "repo": repo, **meta, "config": cfg, "open_prs": len(rows),
                   "clusters": [{"issue": i, **issue_info.get(i, {}), "prs": ns} for i, ns in clus.items()],
                   "merge_ready": ready, "rows": rows}, f, indent=1)
    print(f"{len(rows)} open PRs; {len(clus)} issue cluster(s); {sum(1 for r in rows if r['issue']['kind'] == 'none')} "
          f"with no issue; merge-ready on {', '.join(cfg['roles']['current'])}: {len(ready)}; {meta['seconds']} s "
          f"({', '.join(f'{k} {v} s' for k, v in timing.items())}); written to {a.out}")


if __name__ == "__main__":
    main()
