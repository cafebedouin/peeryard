"""rank.py: the queue rules (queue/rules.json: risk tiers, WIP markers, the stale window), the carried patches and the
claims, and the two rankings (needs a review, needs a maintainer) with the coverage counts. Part of queue/build.py
(see its docstring)."""
import fnmatch, json, os

from ghapi import now_utc

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
RULES = None    # queue/rules.json, set by build.main before anything is ranked


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



def load_claims():
    """queue/claims.json (queue/claim.py edits it): {pr, kind, by, claimed_at, expires_at}; an expired claim is ignored."""
    path = os.path.join(HERE, "claims.json")
    if not os.path.isfile(path):
        return {}
    with open(path) as f:
        j = json.load(f)
    now = now_utc().strftime("%Y-%m-%dT%H:%M:%SZ")
    return {int(c["pr"]): c for c in j.get("claims", []) if c.get("expires_at", "") > now}


def is_wip(r):
    t = r["title"].upper()
    return any(m.upper() in t for m in RULES.get("wip_markers", []))


def needs_rebase(r):
    """GitHub reports conflicts with the base branch: an author action before a maintainer can merge. Such a pull request
    leaves the default review track (its diff against its own merge base is still readable, so a reviewer who wants it may
    still pick it); the state is read from GitHub, nothing is posted, and it clears by itself when the author rebases."""
    return r["mergeable"] == "dirty"


def rank_review(rows):
    """Needs a review: no review at the current head, head pushed within stale_days, not marked WIP. Order: tier,
    then longest at the current head, then smallest."""
    stale = RULES.get("stale_days", 90)
    todo = [r for r in rows if r["reviews_at_head"] == 0 and not r["peeryard_review"] and r["days_at_head"] <= stale and not is_wip(r)
            and not needs_rebase(r)]
    todo.sort(key=lambda r: (r["tier"][0], -r["days_at_head"], r["additions"] + r["deletions"]))
    for r in todo:
        r["why"] = [f"tier {r['tier'][0]} ({r['tier'][1]})", f"{r['days_at_head']} days at this head",
                    f"{r['additions']}+/{r['deletions']}- in {r['files']} files",
                    "links an issue" if r["linked_issue"] else "no linked issue", f"CI {r['ci']}"]
    return todo


def rank_maintainer(rows):
    """Needs a maintainer: reviewed at this head, CI green (or none), mergeable. Order: longest waiting first."""
    todo = [r for r in rows if (r["reviews_at_head"] > 0 or r["peeryard_review"]) and r["ci"] in ("green", "none") and r["mergeable"] in ("clean", "unstable", "has_hooks", "unknown")]
    todo.sort(key=lambda r: (-r["days_waiting"], r["tier"][0]))
    for r in todo:
        r["why"] = [f"{r['days_waiting']} days since the last activity", f"{r['reviews_at_head']} review(s) at this head"
                    + (", approved" if r["approved_at_head"] else "") + peeryard_note(r), f"CI {r['ci']}", ("mergeable: not yet computed by GitHub" if r["mergeable"] == "unknown" else f"mergeable: {r['mergeable']}"),
                    f"tier {r['tier'][0]} ({r['tier'][1]})"]
    return todo


def coverage(rows, review, rebase, wip, stale_days):
    """Where the review work stands, over the live pull requests (head within stale_days, not WIP)."""
    live = [r for r in rows if r["days_at_head"] <= stale_days and not is_wip(r)]
    any_rev = [r for r in live if r["reviews_at_head"] > 0 or r["peeryard_review"]]
    pyd = [r for r in live if r["peeryard_review"]]
    kinds = {}
    for r in pyd:
        k = (r.get("peeryard") or {}).get("kind") or "unknown"
        kinds[k] = kinds.get(k, 0) + 1
    t1 = [r for r in live if r["tier"][0] == 1]
    t1_exec = [r for r in t1 if r["peeryard_review"] and (r.get("peeryard") or {}).get("kind") not in (None, "read", "read-review")]
    return {"live": len(live), "reviewed_at_head": len(any_rev), "peeryard_at_head": len(pyd), "peeryard_carried": sum(1 for r in pyd if (r.get("peeryard") or {}).get("carried_from")),
            "peeryard_kinds": kinds, "needs_review": len(review), "needs_rebase": len(rebase), "wip": len(wip),
            "tier1_live": len(t1), "tier1_executed": len(t1_exec), "stale": sum(1 for r in rows if r["days_at_head"] > stale_days),
            "claimed": sum(1 for r in rows if r.get("claimed"))}


def peeryard_note(r):
    p = r.get("peeryard")
    if not p:
        return ""
    note = "; peeryard review" + (f" ({p['kind']})" if p.get("kind") else "")
    if p.get("carried_from"):
        note += f", carried from head {p['carried_from']} (production diff unchanged)"
    return note
