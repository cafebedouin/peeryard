#!/usr/bin/env bash
# lint.sh: grep files against an optional deny-list of terms (DIFFRUN_TERMS: one extended regex per line, '#'
# comments allowed). Use it when you run scenarios about something not yet public and want the runner to refuse
# to write shareable outputs that mention it. Exit 0 = no hit (or no list set), 1 = hit (each hit is printed as
# file:line:text on stderr), 2 = lint could not run.
#
#   bash diffrun/lint.sh [file ...]
#
# With no arguments it lints every tracked public-tier manifest under diffrun/scenarios/ plus the script and the
# precheck it names.
# It is a known-term backstop, not proof that content is safe to share.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TERMS="${DIFFRUN_TERMS:-}"
[[ -z "$TERMS" ]] && { echo "lint: no DIFFRUN_TERMS set; skipped" >&2; exit 0; }
[[ -r "$TERMS" ]] || { echo "lint: term list not readable: $TERMS" >&2; exit 2; }
PAT="$(mktemp)"; trap 'rm -f "$PAT"' EXIT
grep -vE '^[[:space:]]*(#|$)' "$TERMS" > "$PAT"
[[ -s "$PAT" ]] || { echo "lint: term list is empty: $TERMS" >&2; exit 2; }

files=("$@")
if [[ ${#files[@]} -eq 0 ]]; then
  while IFS= read -r m; do
    [[ "$(jq -r '.tier // empty' "$HERE/../$m" 2>/dev/null)" == public ]] || continue
    files+=("$HERE/../$m")
    s="$(jq -r '.script // empty' "$HERE/../$m")"
    [[ -n "$s" ]] && files+=("$HERE/scenarios/$s")
    p="$(jq -r '.precheck // empty' "$HERE/../$m")"
    [[ -n "$p" ]] && files+=("$HERE/scenarios/$p")
  done < <(cd "$HERE/.." && find diffrun/scenarios -name '*.json' | sort)
  [[ ${#files[@]} -gt 0 ]] || { echo "lint: no public-tier manifests found" >&2; exit 2; }
fi

hit=0
for f in "${files[@]}"; do
  [[ -r "$f" ]] || { echo "lint: not readable: $f" >&2; exit 2; }
  out="$(grep -n -i -E -f "$PAT" -- "$f")"; rc=$?
  [[ $rc == 2 ]] && { echo "lint: grep failed on $f (a bad pattern in the term list?); refusing to pass" >&2; exit 2; }
  if [[ $rc == 0 ]]; then
    hit=1; while IFS= read -r l; do echo "lint: HIT $f:$l" >&2; done <<< "$out"
  fi
done
[[ $hit == 0 ]] && echo "lint: clean (${#files[@]} files)" >&2
exit $hit
