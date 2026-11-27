#!/usr/bin/env python3
"""claim.py: say which pull request you are reviewing, so nobody else starts the same one.

    python3 queue/claim.py --pr N [--by <login>] [--kind read-review,revert-check] [--hours 24]
    python3 queue/claim.py --pr N --release            # the review is posted (or abandoned): drop the claim
    python3 queue/claim.py --list

Edits queue/claims.json (expired claims are pruned on every run) and prints the git commands that publish it: a claim
counts on the public page only once it is on main, which the daily build reads. Those commands are for the person to
run: an agent hands them over and never commits or pushes claims.json itself (AGENTS.md: nothing is pushed without the
person's go). --by defaults to `gh api user`'s login,
then $USER. Nothing is posted to GitHub. The page and queue/next.py read the file; a claim never hides a pull request,
it tags it.
"""
import argparse, datetime as dt, json, os, shlex, subprocess, sys
HERE = os.path.dirname(os.path.abspath(__file__))
PATH = os.path.join(HERE, "claims.json")


def now():
    return dt.datetime.now(dt.timezone.utc)


def load():
    with open(PATH) as f:
        j = json.load(f)
    live = [c for c in j.get("claims", []) if c.get("expires_at", "") > now().strftime("%Y-%m-%dT%H:%M:%SZ")]
    pruned = len(j.get("claims", [])) - len(live)
    j["claims"] = live
    return j, pruned


def save(j):
    j["claims"].sort(key=lambda c: (c["expires_at"], c["pr"]))
    with open(PATH, "w") as f:
        json.dump(j, f, indent=1)
        f.write("\n")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--pr", type=int)
    ap.add_argument("--by", default=None)
    ap.add_argument("--kind", default=None, help="review kinds you intend (review/reviews.yaml), comma-separated")
    ap.add_argument("--hours", type=float, default=24)
    ap.add_argument("--release", action="store_true")
    ap.add_argument("--list", action="store_true")
    a = ap.parse_args()
    j, pruned = load()
    if a.list or not a.pr:
        for c in j["claims"]:
            print(f"#{c['pr']}  {c['by']:<16} {c.get('kind') or '-':<28} until {c['expires_at']}")
        if not j["claims"]:
            print("no live claims")
        if pruned:
            save(j); print(f"({pruned} expired claim(s) pruned in claims.json; the person publishes it, as below)")
            print_publish("prune")
        return
    by = a.by or subprocess.run(["gh", "api", "user", "--jq", ".login"], capture_output=True, text=True).stdout.strip() or os.environ.get("USER", "someone")
    others = [c for c in j["claims"] if c["pr"] != a.pr]
    mine = [c for c in j["claims"] if c["pr"] == a.pr]
    if a.release:
        if not mine:
            print(f"#{a.pr}: no live claim"); return
        j["claims"] = others; save(j)
        print(f"#{a.pr}: claim by {mine[0]['by']} released")
    else:
        if mine and mine[0]["by"] != by:
            print(f"#{a.pr} is claimed by {mine[0]['by']} until {mine[0]['expires_at']}; pick another, or ask them", file=sys.stderr); sys.exit(3)
        t = now()
        j["claims"] = others + [{"pr": a.pr, "by": by, "kind": a.kind, "claimed_at": t.strftime("%Y-%m-%dT%H:%M:%SZ"),
                                 "expires_at": (t + dt.timedelta(hours=a.hours)).strftime("%Y-%m-%dT%H:%M:%SZ")}]
        save(j)
        print(f"#{a.pr}: claimed by {by}" + (f" for {a.kind}" if a.kind else "") + f" for {a.hours:g} h")
    print_publish(f"#{a.pr}")


def print_publish(what):
    root = os.path.dirname(HERE)
    r = shlex.quote(root)
    print("to publish, the person runs (an agent hands this over and does not run it):\n  git -C " + r
          + " commit -qm " + shlex.quote(f"claims: {what}") + " queue/claims.json && git -C " + r + " push -q origin main")


if __name__ == "__main__":
    main()
