#!/usr/bin/env bash
# post.sh <owner/repo> <pr> <report.md> [--kind review|inline|reply] [--queue]: the last gate. Lints the text,
# prints it, states what it contributes (the recipes and verdict lines it carries), and asks for a typed `yes`
# before `gh pr comment`. Saves the posted text beside the report as <report>.posted.md with the comment URL.
# --queue: for an unattended run; instead of asking, appends the item to audits/QUEUE.tsv (repo, pr, kind,
# file, contribution line) for review/queue.sh, which asks for each item when a person is back.
# --ack-agent-files: post although the PR adds or changes agent-instruction files or LLM context dumps that the text
# does not name (see the guard below); without it such a post is refused.
# Env (for tests): PEERYARD_AGENT_FILES_CMD replaces the detector call (it receives the repo and PR).
set -uo pipefail
REPO="$1"; PR="$2"; FILE="$3"; shift 3; KIND=review; QUEUE=0; ACK=0
while [[ $# -gt 0 ]]; do case "$1" in --kind) KIND="$2"; shift 2 ;; --queue) QUEUE=1; shift ;; --ack-agent-files) ACK=1; shift ;; *) echo "post: unknown option $1" >&2; exit 2 ;; esac; done
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "$FILE" ]] || { echo "post: no such file: $FILE" >&2; exit 2; }
# Only the public part of a report is posted: everything above the closing-gate section "## Upstream to peeryard"
# (and the internal "## Not run"/"## Internal" sections that follow it), or above an explicit marker line
# `<!-- internal -->`, whichever comes first. Nothing else cuts: a horizontal rule or an ordinary HTML comment
# is part of the post. The cut text is what is linted and saved.
PUB="$(mktemp)"; trap 'rm -f "$PUB"' EXIT; awk '/^## (Reviews|Upstream to peeryard|Internal|Not run)/{exit} /^<!-- internal -->[[:space:]]*$/{exit} {print}' "$FILE" > "$PUB"
[[ -s "$PUB" ]] || { echo "post: nothing above the closing-gate section in $FILE" >&2; exit 2; }
cmp -s "$PUB" "$FILE" || echo "post: internal sections cut; posting the $(wc -l < "$PUB") lines above the first internal heading or marker"
python3 "$HERE/comment-lint" --kind "$KIND" "$PUB" || { echo "post: the lint FAILed; fix the text first" >&2; exit 3; }
# Guard: files written for AI tools (agent instructions, context dumps) are not part of any fix, and a merged
# instruction file configures every contributor's assistant. The post must name each flagged file by its path, so
# the maintainers see it, unless --ack-agent-files says the omission is deliberate. A failed lookup also refuses.
if [[ -n "${PEERYARD_AGENT_FILES_CMD:-}" ]]; then flags="$($PEERYARD_AGENT_FILES_CMD "$REPO" "$PR")"; frc=$?
else flags="$(bash "$HERE/agent-files.sh" --pr "$REPO" "$PR")"; frc=$?; fi
if [[ $frc == 2 ]]; then
  echo "post: could not check $REPO#$PR for agent-instruction files" >&2; [[ $ACK == 1 ]] || { echo "post: refused (--ack-agent-files posts anyway)" >&2; exit 5; }
elif [[ -n "$flags" ]]; then
  echo "post: $REPO#$PR adds or changes files written for AI tools:"; while read -r l; do echo "  $l"; done <<< "$flags"
  missing="$(awk '{print $NF}' <<< "$flags" | while read -r f; do grep -qF -- "$f" "$PUB" || echo "$f"; done)"
  if [[ -n "$missing" && $ACK != 1 ]]; then
    echo "post: refused: the text does not name $(tr '\n' ' ' <<< "$missing")(name each file in the review, or pass --ack-agent-files)" >&2; exit 5
  fi
fi
echo "----- text to post to $REPO#$PR -----"; cat "$PUB"; echo "----- end -----"
echo "what it contributes: $(grep -c -E '^- \*\*\[' "$FILE") finding(s); executed: $(grep -m1 -E '^Executed:' "$FILE" | cut -c1-160); verdict lines: $(grep -oE '[A-Z_-]+: (PASS|FAIL|SUPPORTS|AGAINST|NULL|DEGENERATE)[^`]*' "$FILE" | head -3 | tr '\n' ' ')"
if [[ $QUEUE == 1 ]]; then
  q="$HERE/../audits/QUEUE.tsv"; mkdir -p "$(dirname "$q")"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$REPO" "$PR" "$KIND" "$(readlink -f "$FILE")" "$(grep -c -E '^- \*\*\[' "$FILE") finding(s); $(grep -m1 -E '^Executed:' "$FILE" | cut -c1-120)" >> "$q"
  echo "queued (not posted): $q; when back, run: bash review/queue.sh"; exit 0
fi
read -r -p "post this as a comment on $REPO#$PR? type yes to post: " ans
[[ "$ans" == yes ]] || { echo "not posted"; exit 1; }
# gh's own exit status decides: on failure nothing is saved as posted and the caller (queue.sh) sees non-zero.
if ! out="$(gh pr comment "$PR" -R "$REPO" --body-file "$PUB" 2>&1)"; then
  echo "post: gh pr comment FAILED; nothing posted, no .posted.md written:" >&2; echo "$out" >&2; rm -f "$PUB"; exit 4
fi
url="$(tail -1 <<< "$out")"
{ echo "# posted $(date -u +%FT%TZ) to $REPO#$PR: $url"; cat "$PUB"; } > "${FILE%.md}.posted.md"; rm -f "$PUB"
echo "posted: $url (saved as ${FILE%.md}.posted.md)"
