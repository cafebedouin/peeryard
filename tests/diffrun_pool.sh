#!/usr/bin/env bash
# diffrun_pool.sh: tests diffrun/pool.sh (one verdict over sharded run.sh outputs) on synthetic shards: no node, no
# jar, a few seconds. Each shard is a run.sh --out as pool.sh reads it (manifest.json, verdict.json). Run from the
# peeryard root:
#   T=$(mktemp -d) bash tests/diffrun_pool.sh
set -uo pipefail
T="${T:?set T to a scratch dir, e.g. T=$(mktemp -d)}"
# T is deleted and recreated below: refuse anything that is not a scratch dir under /tmp or $TMPDIR (where
# mktemp -d puts one), and anything that contains the current directory (T=. from the repo root).
Tr="$(realpath -m -- "$T")"; Tmpr="$(realpath -m -- "${TMPDIR:-/tmp}")"
case "$Tr/" in /tmp/?*/|"$Tmpr"/?*/) ;; *) echo "refusing T='$T': not a scratch dir under /tmp or \$TMPDIR (use T=\$(mktemp -d))" >&2; exit 2 ;; esac
case "$PWD/" in "$Tr"/*) echo "refusing T='$T': it contains the current directory" >&2; exit 2 ;; esac
rm -rf "$T"; mkdir -p "$T"
fail=0
ok(){ printf '%-72s ok\n' "$1"; }
bad(){ printf '%-72s MISMATCH (%s)\n' "$1" "$2"; fail=1; }
eq(){ [[ "$2" == "$3" ]] && ok "$1" || bad "$1" "want $2, got $3"; }

# manifests: M5 = five pairs, base loses in >= 3, candidate never loses (the matrix-paychain shape); MF = the
# falsifier's (base loses in >= 2, min_valid_runs 1); M1 = one valid run per role is enough
man(){ jq -n --argjson n "$1" --argjson base "$2" --argjson mv "${3:-null}" \
  '{name: "pooltest", script: "pooltest.sh", tier: "public", metrics: {lost: "number"}, n: $n,
    expect: {base: $base, candidate: {all: {key: "lost", op: "==", value: 0}}}}
   + (if $mv == null then {} else {min_valid_runs: $mv} end)'; }
man 5 '{"count": {"key": "lost", "op": ">", "value": 0}, "cmp": ">=", "k": 3}' > "$T/M5.json"
man 4 '{"count": {"key": "lost", "op": ">", "value": 0}, "cmp": ">=", "k": 2}' 1 > "$T/MF.json"
man 3 '{"any": {"key": "lost", "op": ">", "value": 0}}' 1 > "$T/M1.json"

# shard <case> <k> <manifest> "<base runs>" "<candidate runs>" [jar-suffix] [key=json ...]: a run is a lost count
# (VALID, metrics {lost}) or I (INCONCLUSIVE, no metrics); runs alternate as run.sh writes them
shard(){ local c="$1" k="$2" m="$3" b="$4" cd="$5" js="${6:-}"; shift 6 2>/dev/null || shift $#
  local d="$T/$c/shard-$k"; mkdir -p "$d"; cp "$m" "$d/manifest.json"
  jq -n --arg b "$b" --arg c "$cd" --arg js "$js" '
    def runs($role; $s): $s | split(" ") | map(select(length > 0)) | to_entries
      | map({role: $role, index: (.key + 1), class: (if .value == "I" then "INCONCLUSIVE" else "VALID" end),
             reason: (if .value == "I" then "no-result" else null end), cause: null, precheck: null,
             versions: (if .value == "I" then null else {A: "1"} end),
             metrics: (if .value == "I" then null else {lost: (.value | tonumber)} end)});
    (runs("base"; $b)) as $rb | (runs("candidate"; $c)) as $rc
    | {verdict_schema_version: 1, scenario: "pooltest", tier: "public", verdict: "X", same_jar: false,
       provenance: {scenario_script_sha256: "s", precheck_sha256: null, env: {}, peeryard_version: "0", runner_rev: "r",
                    host: {kernel: "k", cpus: 4, mem_mb: 16000}},
       sequential: null,
       jars: {base: {jar_sha256: ("b" + $js), expected_app_version: "1"}, candidate: {jar_sha256: "c", expected_app_version: "1"}},
       runs: [range(0; [($rb | length), ($rc | length)] | max) as $i | ($rb[$i] // empty), ($rc[$i] // empty)]}' > "$d/verdict.json"
  local kv; for kv in "$@"; do jq --argjson v "${kv#*=}" "${kv%%=*} = \$v" "$d/verdict.json" > "$d/v.tmp" && mv "$d/v.tmp" "$d/verdict.json"; done; }
pool(){ local c="$1" s="$2" k="$3"; bash diffrun/pool.sh --out "$T/$c/pooled" --shards "$s" --pairs "$k" "$T/$c" > "$T/$c.out" 2> "$T/$c.err"; echo $?; }
v(){ jq -r "$2" "$T/$1/pooled/verdict.json" 2>/dev/null; }

# ---- the four verdicts, S=5 K=1 (P = 5 = n, min_valid_runs 4) ----
for k in 1 2 3 4 5; do shard sup "$k" "$T/M5.json" 1 0; done
eq "SUPPORTS: base loses in 5/5, candidate in 0/5" "0 SUPPORTS" "$(pool sup 5 1) $(v sup .verdict)"
grep -q "pooled n differs" "$T/sup/pooled/table.txt" && bad "... no 'pooled n differs' label when P == n" "label printed" || ok "... no 'pooled n differs' label when P == n"
eq "... n_overridden false, pooled_n_differs false, min_valid_runs 4 (default)" "false false 4 default" "$(v sup '"\(.n_overridden) \(.pooled_n_differs) \(.min_valid_runs) \(.pooled.min_valid_source)"')"
eq "... every run carries its shard; provenance.hosts has one entry per shard" "10 5" "$(v sup '"\([.runs[] | select(.shard)] | length) \(.provenance.hosts | length)"')"
for k in 1 2 3 4 5; do shard aga "$k" "$T/M5.json" 1 "$([[ $k == 3 ]] && echo 1 || echo 0)"; done
eq "AGAINST: the candidate loses once" "0 AGAINST" "$(pool aga 5 1) $(v aga .verdict)"
for k in 1 2 3 4 5; do shard nul "$k" "$T/M5.json" "$([[ $k -le 2 ]] && echo 1 || echo 0)" 0; done
eq "NULL: the base loses in 2/5 only" "0 NULL" "$(pool nul 5 1) $(v nul .verdict)"

# ---- lost shards count against min_valid_runs, they do not shrink the denominator ----
for k in 1 2 3; do shard deg "$k" "$T/M5.json" 1 0; done
eq "DEGENERATE: S=5 K=1, shards 4 and 5 lost (3 valid < 4)" "0 DEGENERATE 3 2" "$(pool deg 5 1) $(v deg '"\(.verdict) \(.per_role.base.valid) \(.per_role.base.inconclusive)"')"
for k in 1 2 3 5; do shard four "$k" "$T/M5.json" 1 0; done
eq "not DEGENERATE: S=5 K=1, shard 4 lost (4 valid >= 4)" "0 SUPPORTS 4 1" "$(pool four 5 1) $(v four '"\(.verdict) \(.per_role.base.valid) \(.per_role.base.inconclusive)"')"
eq "... pooled.shards marks shard 4 lost" "false" "$(v four '.pooled.shards[3].present')"
for k in 1 3; do shard miss "$k" "$T/M5.json" "1 1" "0 0"; done
eq "missing shard, S=3 K=2: base valid = P-K = 4, inconclusive = K = 2" "0 4 2 4 2" "$(pool miss 3 2) $(v miss '"\(.per_role.base.valid) \(.per_role.base.inconclusive) \(.per_role.candidate.valid) \(.per_role.candidate.inconclusive)"')"
grep -qE '^2/base-1 +INCONCLUSIVE \(lost-shard\)' "$T/miss/pooled/table.txt" && ok "... the table lists 2/base-1 as INCONCLUSIVE (lost-shard)" || bad "... lost-shard row in the table" "$(cat "$T/miss/pooled/table.txt")"
eq "... P=6 != n=5 on a SUPPORTS: 'pooled n differs: not citable'" "SUPPORTS 1" "$(v miss .verdict) $(grep -c 'pooled n differs: not citable' "$T/miss/pooled/table.txt")"
grep -q "n overridden" "$T/miss/pooled/table.txt" && bad "... never described as 'n overridden'" "label printed" || ok "... never described as 'n overridden'"
grep -q "min_valid_runs source: default" "$T/miss/pooled/table.txt" && ok "... the table names the min_valid_runs source" || bad "... min_valid_runs source line" "missing"
shard kp 1 "$T/M5.json" "1 1 1" "0 0 0"
eq "S=2 K=3, shard 2 lost: min_valid_runs = ceil(2P/3) = 4 of P=6 (not of S), so 3 valid is DEGENERATE" "0 4 DEGENERATE" "$(pool kp 2 3) $(v kp '"\(.min_valid_runs) \(.verdict)"')"
shard mv1 1 "$T/M1.json" 1 0
eq "manifest min_valid_runs 1, one VALID of three shards: not DEGENERATE" "0 SUPPORTS manifest 1" "$(pool mv1 3 1) $(v mv1 '"\(.verdict) \(.pooled.min_valid_source) \(.min_valid_runs)"')"
for k in 1 2 3; do shard unp "$k" "$T/M5.json" 1 0; done; echo '{"runs": [' > "$T/unp/shard-2/verdict.json"
eq "an unparseable verdict.json is a lost shard, not a refusal" "0 false 2" "$(pool unp 3 1) $(v unp '"\(.pooled.shards[1].present) \(.per_role.base.valid)"')"
for k in 1 2; do shard short "$k" "$T/M5.json" "1 1" "0 0"; done; shard short 3 "$T/M5.json" "1" "0"
eq "a shard with fewer than K pairs is lost" "0 false 4 2" "$(pool short 3 2) $(v short '"\(.pooled.shards[2].present) \(.per_role.base.valid) \(.per_role.base.inconclusive)"')"
for k in 1 2 3 4 5; do shard aa "$k" "$T/M5.json" 1 0 "" '.same_jar=true'; done
pool aa 5 1 > /dev/null; grep -q "A/A control" "$T/aa/pooled/table.txt" && ok "same_jar carried: the pooled table keeps the A/A label" || bad "A/A label" "missing"

# ---- refusals: exit 2, no verdict ----
refused(){ local name="$1" c="$2" s="$3" k="$4" rc; rc="$(pool "$c" "$s" "$k")"
  [[ $rc == 2 && ! -e "$T/$c/pooled/verdict.json" ]] && ok "$name" || bad "$name" "exit $rc, verdict $(ls "$T/$c/pooled" 2>/dev/null)"; }
mkdir -p "$T/zero"; refused "zero shards present -> exit 2, no verdict" zero 3 1
shard one 1 "$T/M5.json" "1 1" "0 0"; refused "S=1 K=5, its one shard short (lost) -> zero present, exit 2" one 1 5
for k in 1 2; do shard rman "$k" "$T/M5.json" 1 0; done; jq '.description = "other"' "$T/M5.json" > "$T/rman/shard-2/manifest.json"
refused "shards with different manifests -> refused" rman 2 1
for k in 1 2; do shard rbase "$k" "$T/M5.json" 1 0 "$([[ $k == 2 ]] && echo x)"; done
refused "shards with different base jars -> refused" rbase 2 1
for k in 1 2; do shard rcand "$k" "$T/M5.json" 1 0 "" "$([[ $k == 2 ]] && echo '.jars.candidate.jar_sha256="d"' || echo '.x=1')"; done
refused "shards with different candidate jars -> refused" rcand 2 1
for k in 1 2; do shard rsame "$k" "$T/M5.json" 1 0 "" ".same_jar=$([[ $k == 2 ]] && echo true || echo false)"; done
refused "shards that differ in same_jar -> refused" rsame 2 1
for k in 1 2; do shard rprov "$k" "$T/M5.json" 1 0 "" ".provenance.runner_rev=\"$k\""; done
refused "shards that differ in provenance (not the host) -> refused" rprov 2 1
for k in 1 2; do shard rhost "$k" "$T/M5.json" 1 0 "" ".provenance.host.cpus=$k"; done
eq "... shards that differ only in the host are pooled" "0" "$(pool rhost 2 1)"
for k in 1 2; do shard rseq "$k" "$T/M5.json" 1 0 "" "$([[ $k == 2 ]] && echo '.sequential={"stopped_by":"rule"}' || echo '.x=1')"; done
refused "a shard that ran the sequential rule -> refused" rseq 2 1
for k in 1 2; do shard rmore "$k" "$T/M5.json" "1 1" "0 0"; done
refused "a shard with more than K pairs -> refused" rmore 2 1

# ---- falsifier: a vote over shard verdicts gives NULL; pooling the runs gives SUPPORTS ----
for k in 1 2; do shard fal "$k" "$T/MF.json" "1 0" "0 0"; done
per="$(for k in 1 2; do jq -r -L diffrun/lib --slurpfile m "$T/MF.json" 'include "diffrun"; $m[0] as $m
  | {base: role_summary($m; "base"; .runs), candidate: role_summary($m; "candidate"; .runs)} | decide(.; 1)' "$T/fal/shard-$k/verdict.json"; done | tr '\n' ' ')"
eq "falsifier: decide over each shard's own runs" "NULL NULL " "$per"
eq "falsifier: pool.sh over the pooled runs" "0 SUPPORTS" "$(pool fal 2 2) $(v fal .verdict)"

[[ $fail == 0 ]] && echo "pool tests: all ok" || { echo "pool tests: MISMATCH (see $T)"; exit 1; }
