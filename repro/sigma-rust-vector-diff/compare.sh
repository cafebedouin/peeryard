#!/usr/bin/env bash
# compare.sh <santa-grade> <santa-checkout> <runner-json> <labels-dir> <out-dir>
# Grades every label with santa-grade and compares each change with the base. <labels-dir>/<prefix><label>/ holds
# one label's build output (manifest.json, actuals/); $LABEL_PREFIX defaults to the workflow's artifact prefix.
# A label with no directory (its build job uploaded nothing) is reported as not built. Env: LABELS (base first),
# CONTROLS, LEAVES, EXPECTED_BASE_FAILING ("<leaf>=<n> ...", empty = not checked). Writes <out-dir>/summary.md and
# <out-dir>/vector-diff.json; exits with santa-grade's status (1 = a control failed).
set -euo pipefail
grader="$1"; santa="$2"; runner_json="$3"; labels_dir="$4"; out="$5"
prefix="${LABEL_PREFIX-sigma-rust-vector-diff-label-}"
: "${LABELS:?}" "${LEAVES:?}"
mkdir -p "$out"
dir_of() {
  local d="$labels_dir/$prefix$1"
  if [[ ! -d "$d" ]]; then
    d="$out/missing/$1"; mkdir -p "$d"
    printf '{"label":"%s","status":"no-artifact","detail":"the build job uploaded nothing"}\n' "$1" > "$d/manifest.json"
  fi
  echo "$d"
}
read -r -a labels <<< "$LABELS"
[[ "${labels[0]}" == base ]] || { echo "compare: the first label must be base" >&2; exit 2; }
args=(--vectors "$santa/vectors" --runner-json "$runner_json" --leaves "$LEAVES" --base "$(dir_of base)")
for l in "${labels[@]:1}"; do args+=(--change "$l=$(dir_of "$l")"); done
for c in ${CONTROLS:-}; do args+=(--control "$c"); done
[[ -z "${EXPECTED_BASE_FAILING:-}" ]] || args+=(--expected "$EXPECTED_BASE_FAILING")
set +e
"$grader" "${args[@]}" --json "$out/vector-diff.json" --summary "$out/summary.md"
rc=$?
set -e
exit $rc
