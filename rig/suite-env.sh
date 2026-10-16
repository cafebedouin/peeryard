#!/usr/bin/env bash
# suite-env.sh: override keys of the rig examples' extra environment in suite.tsv, in place (sweep.yml's scenario_env
# input, on the CI checkout's copy, so run-suite.sh runs each example with the effective env).
#
#   bash rig/suite-env.sh <suite.tsv> '<KEY=VALUE>[;<KEY=VALUE>...]' [name ...]
#
# A key is set only in the rows (of the named examples; no names: every row) whose env column (the fourth) already
# declares it: an example's parameters are its row's to name, with the default written there. A key that none of
# those rows declares is an error, and so is an unknown example name. A value is [A-Za-z0-9._:,-] only: run-suite.sh
# splits the column on spaces and hands each word to env, never eval'd. An empty override string changes nothing.
# Prints one line per row and key set; exits 1, naming the offending item, on anything else.
set -euo pipefail
f="${1:?suite.tsv}"; spec="${2:-}"; shift; [[ $# -gt 0 ]] && shift
[[ -f "$f" ]] || { echo "suite-env: no file $f"; exit 1; }
[[ -n "$spec" ]] || exit 0
names=" $* "
for n in "$@"; do
  awk -F'\t' -v n="$n" '!/^#/ && NF == 5 && $1 == n { found = 1 } END { exit !found }' "$f" \
    || { echo "suite-env: unknown example '$n' (no row in $(basename "$f"))"; exit 1; }
done
IFS=';' read -ra items <<< "$spec"
for it in "${items[@]}"; do
  it="${it#"${it%%[![:space:]]*}"}"; it="${it%"${it##*[![:space:]]}"}"   # trim
  [[ -z "$it" ]] && continue
  [[ "$it" =~ ^([A-Z][A-Z0-9_]*)=([A-Za-z0-9._:,-]+)$ ]] \
    || { echo "suite-env: '$it' is not KEY=VALUE with KEY [A-Z0-9_] and VALUE [A-Za-z0-9._:,-]"; exit 1; }
  k="${BASH_REMATCH[1]}"; v="${BASH_REMATCH[2]}"
  t="$(mktemp)"; hits="$(mktemp)"
  awk -F'\t' -v OFS='\t' -v k="$k" -v v="$v" -v names="$names" -v hits="$hits" '
    !/^#/ && NF == 5 && $4 != "-" && (names == "  " || index(names, " " $1 " ")) {
      m = split($4, w, " "); out = ""; hit = 0
      for (i = 1; i <= m; i++) { if (index(w[i], k "=") == 1) { w[i] = k "=" v; hit = 1 }; out = out (i > 1 ? " " : "") w[i] }
      if (hit) { $4 = out; print $1 > hits }
    }
    { print }' "$f" > "$t"
  if [[ ! -s "$hits" ]]; then
    rm -f "$t" "$hits"
    echo "suite-env: $k is not declared in the env column of ${*:-any row}"; exit 1
  fi
  cat "$t" > "$f"; rm -f "$t"   # in place, keeping the file's mode
  while read -r row; do echo "suite-env: $row env $k=$v"; done < "$hits"
  rm -f "$hits"
done
