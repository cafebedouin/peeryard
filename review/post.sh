#!/usr/bin/env bash
# post.sh <owner/repo> <pr> <report.md> [--kind review|inline|reply] [--queue]: the last gate. Lints the text,
# prints it, states what it contributes (the recipes and verdict lines it carries), and asks for a typed `yes`
# before `gh pr comment`. Saves the posted text beside the report as <report>.posted.md with the comment URL.
# The person runs it, in their own terminal: the answer is read only from a terminal (a piped or redirected stdin is
# refused, exit 6), so neither an agent nor `yes |` can answer for them. Exit: 0 posted (or queued), 1 not posted,
# 2 usage, 3 lint FAIL, 4 gh failed, 5 agent-instruction files not named, 6 stdin not a terminal.
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
  missing="$(cut -d' ' -f5- <<< "$flags" | while read -r f; do grep -qF -- "$f" "$PUB" || echo "$f"; done)"
  if [[ -n "$missing" && $ACK != 1 ]]; then
    echo "post: refused: the text does not name $(tr '\n' ' ' <<< "$missing")(name each file in the review, or pass --ack-agent-files)" >&2; exit 5
  fi
fi
echo "----- text to post to $REPO#$PR -----"; cat "$PUB"; echo "----- end -----"
NF="$(grep -c -E '^(- )?\*\*\[' "$PUB")"   # labelled findings in the posted part (the template's blocks, or a list of them)
echo "what it contributes: $NF finding(s); executed: $(grep -m1 -E '^Executed:' "$PUB" | cut -c1-160); verdict lines: $(grep -oE '[A-Z_-]+: (PASS|FAIL|SUPPORTS|AGAINST|NULL|DEGENERATE)[^`]*' "$PUB" | head -3 | tr '\n' ' ')"
if [[ $QUEUE == 1 ]]; then
  q="$HERE/../audits/QUEUE.tsv"; mkdir -p "$(dirname "$q")"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$REPO" "$PR" "$KIND" "$(readlink -f "$FILE")" "$NF finding(s); $(grep -m1 -E '^Executed:' "$PUB" | cut -c1-120)" >> "$q"
  echo "queued (not posted): $q; when back, run: bash review/queue.sh"; exit 0
fi
# The answer must be typed by the person at a terminal: a pipe (`yes | post.sh`, `printf 'yes\n' | queue.sh`) or a file is
# refused before the question is asked, so an agent or a script cannot answer it. An agent prints this command for the
# person to run in their own terminal (.claude/skills/review-pr/SKILL.md step 6); there is no override.
if [[ ! -t 0 ]]; then
  echo "post: refused: stdin is not a terminal; the person posts, by running this command in their own terminal and typing yes:" >&2
  echo "  bash review/post.sh $REPO $PR $FILE${KIND:+ --kind $KIND}$([[ $ACK == 1 ]] && echo ' --ack-agent-files')" >&2; exit 6
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
