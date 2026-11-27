#!/usr/bin/env bash
# prior.sh <owner/repo> <pr>: has this pull request already been reviewed with peeryard at its current head?
#
# Every peeryard post carries "using peeryard" in its credit line (templates/, enforced by comment-lint; posts made
# before the 2026-09-24 rename carry "using forkbench", the tool's earlier name, and are matched too) and, since
# 2026-11-09, the structured marker `<!-- peeryard {...} -->` (queue/mark.py), so prior reviews are found on GitHub
# itself, whoever posted them. Either is matched here. Prints one line:
#   none                                     no peeryard post on the PR
#   current <url> <date>                     a peeryard post made at the current head: do not review again
#   stale <url> <date> (head pushed <date> by <source>)
#                                            the head moved after the last peeryard post: a re-review may add something
#                                            (the queue page still shows it as carried when the production diff is unchanged)
#   unknown (<why>)                          a GitHub lookup failed: nothing is known, so nothing may be assumed
# Exit 0 for none/stale (a review may proceed), 3 for current (skip unless the person asks for a second review),
# 2 for unknown or a usage error (a caller must not treat it as none).
# Issue comments and review bodies are both searched; a pending (unsubmitted) review is not a post and is skipped.
#
# "At the current head", as queue/build.py decides it: a pull-request review by its commit_id (the head it was made
# on); a comment by the head its marker names; any other post by its time against the head's push time. The push
# time is the force-push event for the head in the PR timeline, else the head's earliest check suite (CI starts on the
# push), else the head commit's committer date: the REST API records no time for an ordinary push, and the committer
# date can predate the push (a commit written before a review and pushed after it would make that review read current).
set -uo pipefail
REPO="${1:-}"; PR="${2:-}"; [[ -n "$REPO" && "$PR" =~ ^[0-9]+$ ]] || { echo "usage: $0 <owner/repo> <pr>" >&2; exit 2; }
unknown(){ echo "unknown ($*)"; exit 2; }
head_sha="$(gh api "repos/$REPO/pulls/$PR" --jq '.head.sha' 2>/dev/null)" || unknown "cannot read $REPO#$PR"
[[ "$head_sha" =~ ^[0-9a-f]{40}$ ]] || unknown "no head sha for $REPO#$PR"
fp="$(gh api "repos/$REPO/issues/$PR/timeline?per_page=100" --paginate \
        --jq '.[] | select(.event == "head_ref_force_pushed") | "\(.commit_id) \(.created_at)"' 2>/dev/null)" || unknown "cannot read the timeline of $REPO#$PR"
push="$(awk -v h="$head_sha" '$1 == h {print $2}' <<< "$fp" | sort | tail -1)"; src=force-push
if [[ -z "$push" ]]; then
  # every page (--jq runs once per page, so the earliest is taken after it)
  push="$(gh api "repos/$REPO/commits/$head_sha/check-suites?per_page=100" --paginate --jq '.check_suites[].created_at | select(. != null)' 2>/dev/null)" \
    || unknown "cannot read the check suites of $head_sha"; push="$(sort <<< "$push" | head -1)"; src=check-suite
fi
if [[ -z "$push" ]]; then
  # no push time on record: the committer date is the best left, and can be earlier than the push
  push="$(gh api "repos/$REPO/commits/$head_sha" --jq '.commit.committer.date' 2>/dev/null)" || unknown "cannot read the head commit $head_sha"
  src=committer-date
fi
[[ "$push" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T ]] || unknown "no push time for $head_sha"
MATCH='ascii_downcase | (contains("using peeryard") or contains("using forkbench") or contains("<!-- peeryard"))'
MHEAD='((.body | capture("<!--\\s*peeryard\\s+(?<j>\\{[\\s\\S]*?\\})\\s*-->") | .j | fromjson? | .head) // "-")'
# one line per post: <time> <url> <head it names or "-">
comments="$(gh api "repos/$REPO/issues/$PR/comments?per_page=100" --paginate \
  --jq ".[] | select((.body // \"\") | $MATCH) | \"\(.created_at) \(.html_url) \($MHEAD)\"" 2>/dev/null)" || unknown "cannot read the comments of $REPO#$PR"
reviews="$(gh api "repos/$REPO/pulls/$PR/reviews?per_page=100" --paginate \
  --jq ".[] | select(.state != \"PENDING\" and .submitted_at != null) | select((.body // \"\") | $MATCH) | \"\(.submitted_at) \(.html_url) \(.commit_id // $MHEAD)\"" 2>/dev/null)" \
  || unknown "cannot read the reviews of $REPO#$PR"
posts="$(printf '%s\n%s\n' "$comments" "$reviews" | grep -v '^$' | sort)"
[[ -z "$posts" ]] && { echo none; exit 0; }
cur=""
while read -r at url h; do
  if [[ "$h" != - ]]; then [[ "$h" == "$head_sha" ]] && cur="$at $url"
  elif [[ "$at" > "$push" ]]; then cur="$at $url"; fi
done <<< "$posts"
if [[ -n "$cur" ]]; then echo "current ${cur#* } ${cur%% *}"; exit 3; fi
last="$(tail -1 <<< "$posts")"; read -r pdate purl _ <<< "$last"
echo "stale $purl $pdate (head pushed $push by $src)"; exit 0
