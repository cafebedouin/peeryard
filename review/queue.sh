#!/usr/bin/env bash
# queue.sh [list]: walk audits/QUEUE.tsv, the items an unattended run prepared with `post.sh --queue`. For each
# item: show the text and its contribution line, ask for a typed `yes`, post through post.sh (which lints again
# and saves what was posted), and mark the line done. `list` only prints the queue.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; Q="$HERE/../audits/QUEUE.tsv"
[[ -f "$Q" ]] || { echo "queue: nothing queued ($Q)"; exit 0; }
if [[ "${1:-}" == list ]]; then awk -F'\t' '{printf "%s  %s#%s  %s  %s\n  %s\n", $1, $2, $3, $4, $5, $6}' "$Q"; exit 0; fi
tmp="$(mktemp)"; n=0
while IFS=$'\t' read -r when repo pr kind file contrib; do
  [[ -z "$when" || "$when" == done* ]] && { echo "$when	$repo	$pr	$kind	$file	$contrib" >> "$tmp"; continue; }
  n=$((n + 1)); echo; echo "===== queued $when: $repo#$pr ($kind) — $contrib"
  if [[ -f "$file" ]] && bash "$HERE/post.sh" "$repo" "$pr" "$file" --kind "$kind"; then echo "done $when	$repo	$pr	$kind	$file	$contrib" >> "$tmp"
  else echo "$when	$repo	$pr	$kind	$file	$contrib" >> "$tmp"; echo "(left in the queue)"; fi
done < "$Q"
mv "$tmp" "$Q"; echo; echo "queue walked: $n item(s) offered; $(grep -c -v '^done' "$Q") left"
