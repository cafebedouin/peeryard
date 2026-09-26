#!/usr/bin/env bash
# leakcheck.sh: nothing from a private issue register travels with peeryard. Fails if the tree (tracked files, or
# every file outside audits/ when not in git) holds a register file (ISSUES.md, issues.json) or a register id
# (one letter and three digits, e.g. E-101, P-071). Run from peeryard/; CI runs it on every push.
set -u
cd "$(dirname "$0")/.." || exit 2
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then files=$(git ls-files -- .); else files=$(find . -type f -not -path './audits/*' | sed 's#^\./##'); fi
fail=0
reg=$(printf '%s\n' "$files" | grep -E '(^|/)(ISSUES\.md|issues\.json)$')
[[ -n "$reg" ]] && { echo "leakcheck: register file in the tree:"; while IFS= read -r l; do echo "  $l"; done <<< "$reg"; fail=1; }
ids=$(printf '%s\n' "$files" | grep -v '^tests/leakcheck.sh$' | xargs -r -d '\n' grep -n -H -E '\b[EPXKRLMASBC]-[0-9]{3}\b' 2>/dev/null)
[[ -n "$ids" ]] && { echo "leakcheck: register ids in the tree:"; while IFS= read -r l; do echo "  ${l:0:160}"; done <<< "$ids"; fail=1; }
[[ $fail == 0 ]] && echo "leakcheck: no register files or ids ($(printf '%s\n' "$files" | wc -l) files)" || exit 1
