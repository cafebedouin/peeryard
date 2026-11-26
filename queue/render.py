"""render.py: the HTML of the queue pages (the review track, the maintainer track, the outcomes page). Part of
queue/build.py (see its docstring)."""
import html, os, re, urllib.error, urllib.parse

from ghapi import api


CSS = """body{font:15px/1.45 system-ui,sans-serif;max-width:64rem;margin:2rem auto;padding:0 1rem;color:#222}
h1,h2{font-weight:600}table{border-collapse:collapse;width:100%}td,th{padding:.35rem .5rem;border-bottom:1px solid #ddd;vertical-align:top;text-align:left}
small{color:#555}.why{color:#555;font-size:.85em}a{color:#0645ad;text-decoration:none}a:hover{text-decoration:underline}
nav a{margin-right:1rem}.tag{display:inline-block;padding:0 .35rem;border:1px solid #bbb;border-radius:3px;font-size:.8em;margin-left:.3rem}"""


def page(title, sections, generated, repo, path_prefix=""):
    h = [f"<!doctype html><meta charset=utf-8><title>{html.escape(title)}</title><style>{CSS}</style>",
         f"<nav><a href='{path_prefix}./'>needs a review</a><a href='{path_prefix}maintainers/'>needs a maintainer</a><a href='{path_prefix}outcomes/'>outcomes</a>"
         f"<a href='https://github.com/cafebedouin/peeryard'>peeryard</a><a href='https://github.com/cafebedouin/peeryard/blob/main/queue/rules.json'>the rules</a></nav>",
         f"<h1>{html.escape(title)}</h1><p><small>Open pull requests of <a href='https://github.com/{repo}/pulls'>{repo}</a>, "
         f"generated {generated} from public GitHub data by <a href='https://github.com/cafebedouin/peeryard/blob/main/queue/build.py'>queue/build.py</a>. "
         f"Every author is ranked by the same rules; a disagreement with a rank is a pull request against <code>queue/rules.json</code>.</small></p>"]
    for heading, intro, rows, cols in sections:
        h.append(f"<h2>{html.escape(heading)}</h2><p><small>{intro}</small></p>")
        if not cols:
            continue                                   # a text-only section (Coverage)
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
    if r.get("claimed"):
        c = r["claimed"]
        notes.append(f"claimed by {c['by']}" + (f" for {c['kind']}" if c.get("kind") else "") + f" until {c['expires_at'][:16].replace('T', ' ')} UTC")
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
         "<code>git patch-id --stable</code> over the changed lines only (<code>git diff -U0</code>), so the same change made "
         "on another base still matches; earliest opened first. Tests, docs and base branch may differ. Machine-readable in "
         "<a href='https://cafebedouin.github.io/peeryard/queue.json'>queue.json</a> (<a href='https://github.com/cafebedouin/peeryard/blob/main/docs/queue-data.md'>fields</a>; "
         "daily snapshots in <a href='https://cafebedouin.github.io/peeryard/history/index.json'>history/</a>): a hint for maintainers, not a verdict." + intro_tail,
         ex_rows, ["pull requests", "what they share"]),
        ("Open pull requests on the same issue", "Open pull requests by different authors that say they address the "
         "same issue (in the title, or after fixes, closes, addresses or refs in the description; an issue only cited "
         "for context does not count) and change at least one of the same production files: alternatives a maintainer may want to read together. A pair "
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


def coverage_text(c, out_counts):
    kinds = ", ".join(f"{k} {v}" for k, v in sorted(c["peeryard_kinds"].items(), key=lambda kv: -kv[1])) or "none"
    return (f"<b>{c['live']}</b> live pull requests (head within the stale window, not WIP): <b>{c['reviewed_at_head']}</b> have a review at "
            f"their head by anyone, <b>{c['peeryard_at_head']}</b> a peeryard review ({c['peeryard_carried']} carried across a rebase; kinds: {kinds}); "
            f"<b>{c['needs_review']}</b> need a review, {c['needs_rebase']} need a rebase first, {c['wip']} are WIP; {c['stale']} more are older than the window. "
            f"Tier 1 (consensus, sync, state, mining): {c['tier1_live']} live, {c['tier1_executed']} with an executed peeryard review. "
            f"Claimed right now: {c['claimed']} (<code>queue/claims.json</code>). Closed after a peeryard review: {out_counts['merged']} merged, "
            f"{out_counts['closed as recommended']} closed as recommended, {out_counts['closed']} closed otherwise (<a href='outcomes/'>outcomes</a>). "
            f"Counts per day accumulate in <a href='history/index.json'>history/</a>. Pick the next item with <code>python3 queue/next.py --minutes 120</code>.")


def reviewed_cell(r):
    p = r.get("peeryard") or {}
    tail = f" <small>{html.escape(p['kind'])}</small>" if p.get("kind") else ""
    if p.get("carried_from"):
        tail += f"<br><small class=why>made at head {p['carried_from']}; the production diff is unchanged since, so it stands</small>"
    return f"<a href='{r['peeryard_review']}'>review</a>{tail}"


def why_cell(r):
    return "<span class=why>" + "; ".join(html.escape(w) for w in r["why"]) + "</span>"
