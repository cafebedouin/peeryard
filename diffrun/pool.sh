#!/usr/bin/env bash
# pool.sh: one verdict over the shards of a sharded run: S runners, each a run.sh --out with K pairs of one
# scenario on the same base and candidate jars (a pair = one base run then one candidate run on the same runner).
#
#   bash diffrun/pool.sh --out DIR --shards S --pairs K <dir>
#
# <dir> holds shard-1/ .. shard-S/, each a run.sh --out (verdict.json and manifest.json are read). The runs of every
# shard are pooled and judged ONCE by the existing rule (role_summary and decide in lib/diffrun.jq) over P = S*K
# dispatched pairs: a vote over per-shard verdicts would not be the same test. min_valid_runs is the manifest's, else
# run.sh's default ceil(2P/3). A shard whose verdict.json is missing or unreadable, whose manifest.json is missing, or
# that ran fewer than K pairs is LOST: it contributes K INCONCLUSIVE runs per role (reason lost-shard), so a lost shard
# counts against min_valid_runs instead of shrinking the denominator.
#
# Refused (exit 2, nothing written): no shard present; shards that differ in the manifest snapshot (sha256), in the
# base or candidate jar sha256, in same_jar, or in provenance other than the host (the pool is one experiment on one
# pair of artifacts); a shard that ran the sequential rule or more than K pairs (the K-pairs accounting would be false).
# Exit codes as run.sh: 0 verdict written (whatever the verdict); 2 refused or error; 5 output lint hit.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$HERE/lib"
err(){ echo "pool: REFUSED: $*" >&2; exit 2; }
usage(){ echo "usage: $0 --out DIR --shards S --pairs K <dir>" >&2; exit 2; }
jql(){ jq -L "$LIB" "$@"; }

OUT=""; S=""; K=""; DIR=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --out) OUT="${2:-}"; shift 2 ;;
    --shards) S="${2:-}"; shift 2 ;;
    --pairs) K="${2:-}"; shift 2 ;;
    -*) usage ;;
    *) [[ -z "$DIR" ]] || usage; DIR="$1"; shift ;;
  esac
done
[[ -n "$OUT" && -n "$DIR" && "$S" =~ ^[1-9][0-9]*$ && "$K" =~ ^[1-9][0-9]*$ ]] || usage
[[ -d "$DIR" ]] || err "not a directory: $DIR"
[[ ! -e "$OUT" || -z "$(ls -A "$OUT" 2>/dev/null)" ]] || err "--out exists and is not empty: $OUT"
P=$((S * K))

# ---- shards: present (verdict.json parses, manifest.json exists, >= K pairs) or lost ----
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
: > "$TMP/present"; MAN=""
for ((k = 1; k <= S; k++)); do
  d="$DIR/shard-$k"; v="$d/verdict.json"
  if ! jq -e 'type == "object" and (.runs | type == "array")' "$v" >/dev/null 2>&1 || [[ ! -f "$d/manifest.json" ]]; then
    echo "pool: shard $k lost (no readable verdict.json and manifest.json)" >&2; continue
  fi
  [[ "$(jq -r '.sequential == null' "$v")" == true ]] || err "shard $k ran the sequential rule (stop_when/max_n): the K-pairs accounting does not hold"
  pairs="$(jq '[([.runs[] | select(.role == "base")] | length), ([.runs[] | select(.role == "candidate")] | length)] | min' "$v")"
  most="$(jq '[([.runs[] | select(.role == "base")] | length), ([.runs[] | select(.role == "candidate")] | length)] | max' "$v")"
  [[ $most -le $K ]] || err "shard $k ran $most pairs, --pairs is $K"
  if [[ $pairs -lt $K ]]; then echo "pool: shard $k lost ($pairs of $K pairs)" >&2; continue; fi
  jq -c --argjson k "$k" --arg msha "$(sha256sum "$d/manifest.json" | cut -d' ' -f1)" \
    '{k: $k, manifest_sha256: $msha, base: .jars.base.jar_sha256, candidate: .jars.candidate.jar_sha256, same_jar,
      prov: (.provenance | del(.host)), host: .provenance.host, verdict: .}' "$v" >> "$TMP/present"
  [[ -n "$MAN" ]] || MAN="$d/manifest.json"
done
[[ -s "$TMP/present" ]] || err "no shard present (nothing ran); no verdict"
for f in manifest_sha256 base candidate same_jar prov; do
  n="$(jq -s --arg f "$f" '[.[][$f]] | unique | length' "$TMP/present")"
  [[ $n == 1 ]] || err "shards differ in $f: $(jq -sc --arg f "$f" '[.[] | {k, v: .[$f]}]' "$TMP/present")"
done
jql -e 'include "diffrun"; validate_manifest | length == 0' "$MAN" >/dev/null || err "the shards' manifest does not validate: $MAN"

# ---- the pooled verdict ----
mkdir -p "$OUT" || err "cannot create --out: $OUT"; OUT="$(realpath -e "$OUT")"
PEND="$OUT/.pending"; mkdir -p "$PEND" || err "cannot create $PEND"
jql -n --slurpfile m "$MAN" --slurpfile pr "$TMP/present" --argjson S "$S" --argjson K "$K" --argjson P "$P" '
  include "diffrun";
  $m[0] as $m
  | ([$pr[].k]) as $have
  | ([range(1; $S + 1)] | map(select(. as $k | $have | index($k) | not))) as $lost
  | ([$pr[] | .k as $k | .verdict.runs[] | . + {shard: $k}]
     + [$lost[] as $k | ("base", "candidate") as $role | range(1; $K + 1) as $i
        | {role: $role, index: $i, class: "INCONCLUSIVE", reason: "lost-shard", cause: null, precheck: null,
           versions: null, metrics: null, shard: $k}] | sort_by(.shard)) as $runs
  | (if $m | has("min_valid_runs") then {v: $m.min_valid_runs, src: "manifest"} else {v: (((2 * $P) + 2) / 3 | floor), src: "default"} end) as $minv
  | { base: role_summary($m; "base"; $runs), candidate: role_summary($m; "candidate"; $runs) } as $per
  | $pr[0].verdict as $v0
  | { verdict_schema_version: 1, scenario: $m.name, tier: $m.tier, verdict: decide($per; $minv.v),
      precedence: ["DEGENERATE", "AGAINST", "NULL", "SUPPORTS"],
      same_jar: $pr[0].same_jar,
      provenance: ($pr[0].prov + {hosts: [$pr[] | {shard: .k, host}]}),
      precheck: (if $m | has("precheck") then { script: $m.precheck, failed: ([$runs[] | select(.precheck == "fail")] | length) } else null end),
      n_manifest: $m.n, n_min: $P, n_run: $P, n_overridden: false, pooled_n_differs: ($P != $m.n), min_valid_runs: $minv.v,
      sequential: null,
      expect: $m.expect,
      jars: $v0.jars,
      per_role: $per, runs: $runs,
      pooled: { shards: [range(1; $S + 1) as $k | {k: $k, present: ($have | index($k) != null),
                                                   runs: ([$runs[] | select(.shard == $k and .reason != "lost-shard")] | length)}],
                pairs_per_shard: $K, pairs_dispatched: $P, min_valid_source: $minv.src } }' > "$PEND/verdict.json" \
  || err "verdict evaluation failed"
jql -r 'include "diffrun"; render_table' "$PEND/verdict.json" > "$PEND/table.txt" || err "table rendering failed"

# output lint: the same leak path as run.sh's; nothing is written on a hit
bash "$HERE/lint.sh" "$PEND/verdict.json" "$PEND/table.txt"; rc=$?
if [[ $rc != 0 ]]; then
  rm -rf "$PEND"
  [[ $rc == 1 ]] && { echo "pool: REFUSED: output lint hit; verdict.json and table.txt NOT written" >&2; exit 5; }
  err "output lint could not run; verdict.json and table.txt NOT written"
fi
mv "$PEND/verdict.json" "$PEND/table.txt" "$OUT/" && rmdir "$PEND" || err "cannot move outputs into $OUT"
cat "$OUT/table.txt"
echo "pool: verdict written: $OUT/verdict.json" >&2
