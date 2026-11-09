#!/usr/bin/env python3
"""mark.py: the marker a peeryard review carries, so the queue page and review/prior.sh can find it and carry it.

    python3 queue/mark.py --pr N [--repo ergoplatform/ergo] [--kind read-review|revert-check|scenario|...] [--git-cache DIR]

Prints one line to append to the review body (GitHub hides an HTML comment from readers):

    <!-- peeryard {"head": "<full sha>", "base": "<branch>", "kind": "<kind>", "prod_patch_id": "<id or null>", "at": "<utc>"} -->

head is the pull request's head commit at the time of the review; prod_patch_id is `git patch-id --stable` of the
production diff (src/main and */src/main, changed lines only, from the merge base with the base branch), the same id
queue/build.py computes for the same-change view. With it the page can tell a later rebase or tests-only push (same
id: the review stands, shown as carried) from a production change (the pull request returns to the needs-a-review
track). kind is one of review/reviews.yaml, or a comma-separated list; the page shows it. The blobless bare clone
build.py keeps (--git-cache) is used and created when missing (one-time, a few minutes).
"""
import argparse, datetime as dt, json, os, subprocess, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import build


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", default="ergoplatform/ergo")
    ap.add_argument("--pr", type=int, required=True)
    ap.add_argument("--kind", default="read-review", help="a kind from review/reviews.yaml, or several comma-separated")
    ap.add_argument("--git-cache", default=os.path.join(os.path.expanduser("~"), ".cache", "peeryard", "queue"))
    a = ap.parse_args()
    token = os.environ.get("GITHUB_TOKEN") or subprocess.run(["gh", "auth", "token"], capture_output=True, text=True).stdout.strip() or None
    p = build.api(f"/repos/{a.repo}/pulls/{a.pr}", token=token)
    head, base = p["head"]["sha"], p["base"]["ref"]
    gdir = os.path.join(a.git_cache, a.repo.replace("/", "_") + ".git")
    if not os.path.isdir(gdir):
        os.makedirs(os.path.dirname(gdir), exist_ok=True)
        subprocess.run(["git", "clone", "-q", "--bare", "--filter=blob:none", "--no-tags", f"https://github.com/{a.repo}.git", gdir],
                       check=True)
    build.git(gdir, "fetch", "-q", "--no-tags", "origin", f"+refs/heads/{base}:refs/heads/{base}", head)
    mb = build.git(gdir, "merge-base", f"refs/heads/{base}", head).split()[0]
    pid, changed = build.production_patch_id(gdir, mb, head, "-U0")
    rec = {"head": head, "base": base, "kind": a.kind, "prod_patch_id": pid if changed else None,
           "at": dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")}
    print("<!-- peeryard " + json.dumps(rec) + " -->")


if __name__ == "__main__":
    main()
