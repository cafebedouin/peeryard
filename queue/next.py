#!/usr/bin/env python3
"""next.py: what to review next, within a time budget, from the published queue data. The rules pick; a person or a model
takes the list as given.

    python3 queue/next.py [--minutes 120] [--me <login>] [--tier 1,2] [--from URL-or-file] [--json]

Reads queue.json (default: the published page's), walks the needs-a-review track in its rank order (tier, then days at
the current head, then size), skips pull requests claimed by someone else (queue/claims.json: the local file, and the claims the page was built with), and fills the
budget with a cost estimate per item: a read-review of a small change (under 80 changed lines) 20 min, medium (under 400)
45, large 90; a tier-1 or tier-2 production change that also changes tests adds a revert-check (25 min, sbt); a
tests-only change is a revert-check alone; docs are a read. A pull request in a same-change or same-issue group is one
item with its group: review them together and say which to keep. For each item it prints the kinds, the estimate, the
rule lines that ranked it, and the two commands that make the review findable and the claim visible
(queue/mark.py, queue/claim.py). The estimates are the rule's, not a measurement; change them in RULES below by pull request.
"""
import argparse, datetime as dt, json, os, sys, urllib.request

DEFAULT = "https://cafebedouin.github.io/peeryard/queue.json"
HERE = os.path.dirname(os.path.abspath(__file__))
RULES = {"read_small": 20, "read_medium": 45, "read_large": 90, "small": 80, "medium": 400, "revert_check": 25, "compare_extra": 15}


def load(src):
    if src.startswith("http"):
        with urllib.request.urlopen(src, timeout=60) as r:
            return json.loads(r.read().decode())
    with open(src) as f:
        return json.load(f)


def plan(r):
    lines = r["additions"] + r["deletions"]
    size = "small" if lines < RULES["small"] else "medium" if lines < RULES["medium"] else "large"
    prod = r.get("production_files") or []
    tests = r["files"] - len(prod) > 0 and r["tier"][0] in (1, 2, 3)
    kinds, minutes = [], 0
    if prod:
        kinds.append("read-review"); minutes += RULES["read_" + size]
        if tests and r["tier"][0] in (1, 2):
            kinds.append("revert-check"); minutes += RULES["revert_check"]
    elif r["tier"][0] == 3:
        kinds.append("revert-check"); minutes += RULES["revert_check"]
    else:
        kinds.append("read"); minutes += RULES["read_small"]
    group = []
    if r.get("same_change_later"):
        group = [f"same change as #{n}" for n in r["same_change_later"]]
    if r.get("same_change_as"):
        group.append(f"same change as #{r['same_change_as']} (earlier)")
    for s in r.get("same_issue") or []:
        group.append(f"issue #{s['issue']} with " + ", ".join(f"#{n}" for n in s["with"]))
    if group:
        kinds.append("compare"); minutes += RULES["compare_extra"]
    return kinds, minutes, size, group


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--minutes", type=int, default=120)
    ap.add_argument("--me", default=None, help="your login: your own claims are kept, others' are skipped")
    ap.add_argument("--tier", default=None, help="only these tiers, e.g. 1,2")
    ap.add_argument("--from", dest="src", default=DEFAULT)
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args()
    q = load(a.src)
    by = {r["number"]: r for r in q["rows"]}
    # claims: the published rows carry the claims on main at build time; the local claims.json may be newer (yours, a minute ago)
    try:
        with open(os.path.join(HERE, "claims.json")) as f:
            now = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
            for c in json.load(f).get("claims", []):
                if c.get("expires_at", "") > now and int(c["pr"]) in by:
                    by[int(c["pr"])]["claimed"] = {"by": c["by"], "kind": c.get("kind"), "expires_at": c["expires_at"]}
    except (OSError, ValueError):
        pass
    tiers = {int(t) for t in a.tier.split(",")} if a.tier else None
    picked, left, skipped = [], a.minutes, []
    for n in q["needs_review"]:
        r = by.get(n)
        if not r or (tiers and r["tier"][0] not in tiers):
            continue
        c = r.get("claimed")
        if c and c["by"] != a.me:
            skipped.append((n, c["by"])); continue
        kinds, minutes, size, group = plan(r)
        if minutes > left and picked:
            continue
        picked.append({"pr": n, "title": r["title"], "author": r["author"], "tier": r["tier"][0], "kinds": kinds, "minutes": minutes,
                       "size": f"{size} ({r['additions']}+/{r['deletions']}- in {r['files']} files)", "why": r.get("why", []), "group": group,
                       "url": r["url"], "base": r["base"]})
        left -= minutes
        if left <= 0:
            break
    if a.json:
        print(json.dumps({"generated": q["generated"], "budget_minutes": a.minutes, "items": picked, "skipped_claimed": skipped}, indent=1)); return
    print(f"queue of {q['generated']}: {len(q['needs_review'])} need a review; {a.minutes} min budget -> {len(picked)} item(s), {a.minutes - left} min planned")
    for i, p in enumerate(picked, 1):
        print(f"\n{i}. #{p['pr']}  {p['title']}  ({p['author']}, base {p['base']}, tier {p['tier']})")
        print(f"   kinds: {', '.join(p['kinds'])}   ~{p['minutes']} min   {p['size']}")
        if p["group"]:
            print("   group: " + "; ".join(p["group"]) + "  -> one compare verdict over the set")
        print("   why:   " + "; ".join(p["why"]))
        print(f"   {p['url']}")
        print(f"   claim: python3 queue/claim.py --pr {p['pr']} --kind {','.join(k for k in p['kinds'] if k != 'compare')}")
        print(f"   mark:  python3 queue/mark.py --pr {p['pr']} --kind {','.join(k for k in p['kinds'] if k != 'compare')}   # last line of the review")
    if skipped:
        print("\nskipped, claimed by others: " + ", ".join(f"#{n} ({b})" for n, b in skipped))


if __name__ == "__main__":
    main()
