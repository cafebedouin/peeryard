#!/usr/bin/env bash
# prior.sh <owner/repo> <pr>: has this pull request already been reviewed with peeryard at its current head?
#
# Every peeryard post carries "using peeryard" in its credit line (templates/, enforced by comment-lint; posts made
# before the 2026-09-24 rename carry "using forkbench", the tool's earlier name, and are matched too), so prior
# reviews are found on GitHub itself, whoever posted them. Prints one line:
#   none                                     no peeryard post on the PR
#   current <url> <date>                     a peeryard post newer than the head commit: do not review again
#   stale <url> <date> (head pushed <date>)  the head moved after the last peeryard post: a re-review may add something
# Exit 0 for none/stale (a review may proceed), 3 for current (skip unless the person asks for a second review).
# Issue comments and review bodies are both searched.
set -uo pipefail
REPO="${1:-}"; PR="${2:-}"; [[ -n "$REPO" && -n "$PR" ]] || { echo "usage: $0 <owner/repo> <pr>" >&2; exit 2; }
head_date="$(gh pr view "$PR" -R "$REPO" --json commits -q '.commits[-1].committedDate' 2>/dev/null)"
posts="$( { gh api "repos/$REPO/issues/$PR/comments?per_page=100" --paginate --jq '.[] | select(.body | ascii_downcase | (contains("using peeryard") or contains("using forkbench"))) | "\(.created_at) \(.html_url)"' 2>/dev/null
            gh api "repos/$REPO/pulls/$PR/reviews?per_page=100" --paginate --jq '.[] | select((.body // "") | ascii_downcase | (contains("using peeryard") or contains("using forkbench"))) | "\(.submitted_at) \(.html_url)"' 2>/dev/null; } | sort | tail -1)"
[[ -z "$posts" ]] && { echo none; exit 0; }
pdate="${posts%% *}"; purl="${posts#* }"
if [[ -n "$head_date" && "$pdate" > "$head_date" ]]; then echo "current $purl $pdate"; exit 3; fi
echo "stale $purl $pdate (head pushed $head_date)"; exit 0
