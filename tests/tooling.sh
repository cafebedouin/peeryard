#!/usr/bin/env bash
# tooling.sh: tests patches/check.sh, patches/stack.sh, patches/mutate.sh, diffrun/register.sh, diffrun/pool.sh, rig/suite-env.sh,
# rig/lib/blockwatch.sh (against a stubbed REST API) and review/provenance.sh on local
# fixtures (a throwaway git repository and fake jars); no network, no node. Run from the peeryard root:
#   T=$(mktemp -d) bash tests/tooling.sh
set -uo pipefail
# the fixtures are git repositories and several helpers are Python: say what is missing once, instead of a cascade
miss=(); for t in git python3; do command -v "$t" >/dev/null 2>&1 || miss+=("$t"); done
[[ ${#miss[@]} -eq 0 ]] || { echo "tests/tooling.sh needs ${miss[*]} (see the run card in README.md); not run" >&2; exit 2; }
T="${T:?set T to a scratch dir, e.g. T=$(mktemp -d)}"
# T is deleted and recreated below: refuse anything that is not a scratch dir under /tmp or $TMPDIR (where
# mktemp -d puts one), and anything that contains the current directory (T=. from the repo root).
Tr="$(realpath -m -- "$T")"; Tmpr="$(realpath -m -- "${TMPDIR:-/tmp}")"
case "$Tr/" in /tmp/?*/|"$Tmpr"/?*/) ;; *) echo "refusing T='$T': not a scratch dir under /tmp or \$TMPDIR (use T=\$(mktemp -d))" >&2; exit 2 ;; esac
case "$PWD/" in "$Tr"/*) echo "refusing T='$T': it contains the current directory" >&2; exit 2 ;; esac
rm -rf "$T"; mkdir -p "$T"
fail=0
ok(){ printf '%-58s ok\n' "$1"; }
bad(){ printf '%-58s MISMATCH (%s)\n' "$1" "$2"; fail=1; }
expect_rc(){ local name=$1 want=$2 got=$3; [[ "$got" == "$want" ]] && ok "$name" || bad "$name" "want exit $want, got $got"; }
expect_in(){ local name=$1 needle=$2 file=$3; grep -qF -- "$needle" "$file" && ok "$name" || bad "$name" "no '$needle' in $file"; }

# ---- fixture repository: v1 (release), v2 = v1 + the patch (landed), v3 = v1 with the patched line changed
R="$T/repo"; git init -q "$R"; g(){ git -C "$R" -c user.name=t -c user.email=t@t "$@"; }
printf 'one\ntwo\nthree\n' > "$R/a.txt"; g add a.txt; g commit -q -m v1; g tag v1
sed -i 's/^two$/TWO/' "$R/a.txt"; g diff > "$T/001.patch"; g commit -qam v2; g tag v2
g checkout -q v1; sed -i 's/^two$/zwei/' "$R/a.txt"; g commit -qam v3; g tag v3; g checkout -q --detach v1
mkdir -p "$T/patches/fx"; cp "$T/001.patch" "$T/patches/fx/001.patch"
fx(){ jq -n --arg s "$1" '{repo: "example/fx", base: "v1", clone_env: "FX_CLONE", build: "none",
  stack_statuses: ["proposed"], patches: [{id: "001", file: "001.patch", title: "two to TWO", status: $s, upstream_pr: null}]}' \
  > "$T/patches/fx/patches.json"; }
chk(){ PEERYARD_PATCHES_DIR="$T/patches" PEERYARD_OFFLINE=1 FX_CLONE="$R" bash patches/check.sh fx "$1" > "$T/check-$2.txt" 2>&1; echo $?; }

fx proposed
expect_rc "check.sh: stacked patch on its release -> exit 0" 0 "$(chk v1 v1)"; expect_in "check.sh: ... verdict NEEDED" NEEDED "$T/check-v1.txt"
expect_rc "check.sh: stacked patch already in the tag -> exit 1" 1 "$(chk v2 v2)"; expect_in "check.sh: ... verdict CONTAINED" CONTAINED "$T/check-v2.txt"
expect_rc "check.sh: stacked patch on changed lines -> exit 1" 1 "$(chk v3 v3)"; expect_in "check.sh: ... verdict COLLIDES" COLLIDES "$T/check-v3.txt"
fx candidate
expect_rc "check.sh: a candidate (not stacked) never fails the check" 0 "$(chk v2 v2c)"; expect_in "check.sh: ... still reports CONTAINED" CONTAINED "$T/check-v2c.txt"
g branch -q fx-line v2
expect_rc "check.sh: a branch ref (not a tag) is accepted, e.g. a branch-based folder" 0 "$(chk fx-line br)"; expect_in "check.sh: ... verdict CONTAINED on the branch" CONTAINED "$T/check-br.txt"
expect_rc "check.sh: offline without a tag -> usage error" 2 "$(PEERYARD_PATCHES_DIR="$T/patches" PEERYARD_OFFLINE=1 FX_CLONE="$R" bash patches/check.sh fx > /dev/null 2>&1; echo $?)"

# rig/rig.sh _cmp_input_chain: /blocks/bestInputChain lists tip first, so a node behind holds a suffix of the leader's list
eval "$(awk '/^_cmp_input_chain\(\)/{f=1} f{print} f && /end\x27; }$/{exit}' rig/rig.sh)"
ic(){ printf '{"bestOrdering":"%s","bestInputBlocks":%s}' "$1" "$2"; }
expect_eq(){ [[ "$2" == "$3" ]] && ok "$1" || bad "$1" "want $2, got $3"; }
expect_eq "cmp_input_chain: equal lists -> SAME" "SAME@oo:3" "$(_cmp_input_chain "$(ic oo '["c","b","a"]')" "$(ic oo '["c","b","a"]')")"
expect_eq "cmp_input_chain: B one behind (tip-first suffix) -> PREFIX" "PREFIX@oo:A=3:B=2" "$(_cmp_input_chain "$(ic oo '["c","b","a"]')" "$(ic oo '["b","a"]')")"
expect_eq "cmp_input_chain: A behind -> PREFIX" "PREFIX@oo:A=1:B=3" "$(_cmp_input_chain "$(ic oo '["a"]')" "$(ic oo '["c","b","a"]')")"
expect_eq "cmp_input_chain: B holds the newest, not the oldest -> DIFF" "DIFF@oo:A=3:B=2" "$(_cmp_input_chain "$(ic oo '["c","b","a"]')" "$(ic oo '["c","b"]')")"
expect_eq "cmp_input_chain: B empty -> PREFIX" "PREFIX@oo:A=2:B=0" "$(_cmp_input_chain "$(ic oo '["b","a"]')" "$(ic oo '[]')")"
expect_eq "cmp_input_chain: different ordering block -> DIFF-ORD" "DIFF-ORD@o1/o2" "$(_cmp_input_chain "$(ic o1 '["a"]')" "$(ic o2 '["a"]')")"

# rig/rig.sh relink: after the grace, a missing link touching the named nodes is re-dialled from a JVM end, counted in
# RELINK_DIALS; a link of other nodes and a partitioned link are left alone; a link that never comes back returns 1
rl(){ ( eval "$(awk '/^relink\(\)/{f=1} f{print} f && /sleep 2; done; }$/{exit}' rig/rig.sh)"
  LINK_A=(A B A); LINK_B=(B C C); declare -A KIND=([A]=jvm [B]=jvm [C]=jvm) IP=([A]=10.0.0.1 [B]=10.0.0.2 [C]=10.0.0.3)
  declare -A P2P=([A]=1 [B]=2 [C]=3) PARTITIONED=([A,C]=1) NAME_OF=([10.0.0.1]=A [10.0.0.2]=B [10.0.0.3]=C)
  peers_of(){ awk -v n="$1" '$1 == n { print $2 } $2 == n { print $1 }' "$T/rl-conn" | sort -u | tr '\n' ' '; }
  wallet(){ local ip="${3//\"/}"; ip="${ip%%:*}"; echo "$1 -> ${NAME_OF[$ip]}" >> "$T/rl-dials"
    [[ "${RL_HEAL:-1}" == 1 ]] && echo "$1 ${NAME_OF[$ip]}" >> "$T/rl-conn"; }
  RELINK_DIALS=0; PEERYARD_RELINK_GRACE_S=0 relink "$@"; echo "rc=$? dials=$RELINK_DIALS" ) > "$T/rl.out" 2>&1; }
: > "$T/rl-dials"; printf 'B C\n' > "$T/rl-conn"; rl 20 A
expect_in "relink: A-B missing -> re-dialled from A, returns 0" "rc=0 dials=1" "$T/rl.out"
expect_in "relink: ... dialled B" "A -> B" "$T/rl-dials"; expect_in "relink: ... printed" "re-dialled B from A" "$T/rl.out"
: > "$T/rl-dials"; printf 'A B\n' > "$T/rl-conn"; rl 20 C
expect_in "relink: B-C missing, A-C partitioned, relink C -> B-C only" "rc=0 dials=1" "$T/rl.out"
expect_in "relink: ... dialled C from B" "B -> C" "$T/rl-dials"
: > "$T/rl-dials"; printf 'A B\n' > "$T/rl-conn"; rl 20 A
expect_in "relink: A's links up (B-C missing elsewhere) -> no dial" "rc=0 dials=0" "$T/rl.out"
: > "$T/rl-dials"; printf 'B C\n' > "$T/rl-conn"; RL_HEAL=0 rl 3 A
expect_in "relink: a link that never returns -> exit 1" "still not connected after the re-dials" "$T/rl.out"
grep -q "rc=1" "$T/rl.out" && ok "relink: ... rc=1" || bad "relink: never returns" "$(tail -1 "$T/rl.out")"

# rig/lib/hook_api.sh settle_follow: with SETTLE_RELINK_S, relink follows each of the leader's two relaunches; unset, none
sf(){ ( eval "$(awk '/^settle_follow\(\)/{f=1} f{print} /^settle_relink\(\)/{g=1} g{print} g && /; }$/{exit}' rig/lib/hook_api.sh)"
  full_height(){ echo 10; }; start_mining(){ :; }; stop_mining(){ :; }; settle_height_back(){ :; }; sleep(){ :; }
  same_state(){ echo "SAME@20:x"; }; relink(){ echo "relink $*" >> "$T/sf-calls"; }
  settle_follow L F 15 5; echo "rc=$?" ) > "$T/sf.out" 2>&1; }
: > "$T/sf-calls"; SETTLE_RELINK_S=90 sf
expect_eq "settle_follow: SETTLE_RELINK_S=90 -> relink after both relaunches" "relink 90 L|relink 90 L" "$(paste -sd'|' "$T/sf-calls")"
expect_in "settle_follow: ... still settles" "rc=0" "$T/sf.out"
: > "$T/sf-calls"; sf
expect_eq "settle_follow: SETTLE_RELINK_S unset -> no relink" "" "$(cat "$T/sf-calls")"

# diag/diagnose.py: the ConvergenceDiagnosis spec, case for case (tests/diagnose_test.py)
if python3 tests/diagnose_test.py > "$T/diagnose.txt" 2>&1; then ok "diagnose.py: $(grep -oE 'Ran [0-9]+ tests' "$T/diagnose.txt")"
else bad "diagnose.py: the ported spec" "see $T/diagnose.txt"; fi

# diag/features.py: log feature extraction, container ordering and ranking (tests/features_test.py)
if python3 tests/features_test.py > "$T/features.txt" 2>&1; then ok "features.py: $(grep -oE 'Ran [0-9]+ tests' "$T/features.txt")"
else bad "features.py: extraction and ranking" "see $T/features.txt"; fi

# diag/sweep.py: templates, run discovery, robust z, novelty against a baseline (tests/sweep_test.py)
if python3 tests/sweep_test.py > "$T/sweep.txt" 2>&1; then ok "sweep.py: $(grep -oE 'Ran [0-9]+ tests' "$T/sweep.txt")"
else bad "sweep.py: templates and novelty" "see $T/sweep.txt"; fi

# diag/logmap.py: log line -> source site (tests/logmap_test.py)
if python3 tests/logmap_test.py > "$T/logmap.txt" 2>&1; then ok "logmap.py: $(grep -oE 'Ran [0-9]+ tests' "$T/logmap.txt")"
else bad "logmap.py: indexing and matching" "see $T/logmap.txt"; fi

# diag/costs.py: agreement by tip equality at two consecutive samples, windows per heal/revive/relaunch (tests/costs_test.py)
if python3 tests/costs_test.py > "$T/costs.txt" 2>&1; then ok "costs.py: $(grep -oE 'Ran [0-9]+ tests' "$T/costs.txt")"
else bad "costs.py: recovery windows and agreement" "see $T/costs.txt"; fi

# diag/matrix_prop.py: Matrix input-block reach, hop latency, duplicates (tests/matrix_prop_test.py)
if python3 tests/matrix_prop_test.py > "$T/matrix_prop.txt" 2>&1; then ok "matrix_prop.py: $(grep -oE 'Ran [0-9]+ tests' "$T/matrix_prop.txt")"
else bad "matrix_prop.py: reach and hop latency" "see $T/matrix_prop.txt"; fi
# diag/matrix_tx.py: Matrix input-block transaction paths and request/answer pairing (tests/matrix_tx_test.py)
if python3 tests/matrix_tx_test.py > "$T/matrix_tx.txt" 2>&1; then ok "matrix_tx.py: $(grep -oE 'Ran [0-9]+ tests' "$T/matrix_tx.txt")"
else bad "matrix_tx.py: transaction paths and pairing" "see $T/matrix_tx.txt"; fi
# diag/matrix_paychain.py: dependent / lost payments of matrix-paychain (tests/matrix_paychain_test.py)
if python3 tests/matrix_paychain_test.py > "$T/matrix_paychain.txt" 2>&1; then ok "matrix_paychain.py: $(grep -oE 'Ran [0-9]+ tests' "$T/matrix_paychain.txt")"
else bad "matrix_paychain.py: dependent and lost payments" "see $T/matrix_paychain.txt"; fi

# rig/examples/matrix-paychain.sh under diffrun: the activity floor (default 3/4 of N = 30 of 40). The hook's
# DIFFRUN_ROLE block runs on stub payment logs: 29 accepted -> INCONCLUSIVE and no RESULT_JSON; 30 -> RESULT_JSON with floor 30
eval "hookfloor(){ $(awk '/^if \[\[ -n "\$\{DIFFRUN_ROLE:-\}" \]\]; then$/{f=1} f{print} f && /^fi$/{exit}' rig/examples/matrix-paychain.sh)
}"
pays(){ local d="$T/paychain-$1"; mkdir -p "$d"; : > "$d/a_pool_end.txt"
  for i in $(seq 1 "$1"); do echo "{\"id\":\"p$i\",\"inputs\":[\"c$i\"],\"outputs\":[\"o$i\"]}"; done > "$d/payments.jsonl"
  for i in $(seq 1 "$1"); do echo "{\"id\":\"p$i\",\"height\":5}"; done > "$d/confirmed.jsonl"; echo "$d"; }
floor_out(){ local rig_verdict=PASS; RIG_LOG_DIR="$(pays "$1")" N=40 PC=diag/matrix_paychain.py VA=v VB=v DIFFRUN_ROLE="$2" hookfloor; echo "rig_verdict=$rig_verdict"; }
o29="$(floor_out 29 base)"; o30="$(floor_out 30 base)"; onone="$(floor_out 29 "")"
[[ "$o29" != *RESULT_JSON* && "$o29" == *"INCONCLUSIVE: accepted 29 < floor 30"* && "$o29" == *rig_verdict=INCONCLUSIVE* ]] \
  && ok "matrix-paychain hook: 29 accepted < floor 30 -> INCONCLUSIVE" || bad "matrix-paychain hook: 29 accepted" "$o29"
[[ "$(sed -n 's/^RESULT_JSON //p' <<< "$o30" | jq -c '[.metrics.floor, .metrics.accepted, .metrics.lost, .scenario]')" == '[30,30,0,"matrix-paychain"]' ]] \
  && ok "matrix-paychain hook: 30 accepted -> RESULT_JSON, floor 30" || bad "matrix-paychain hook: 30 accepted" "$o30"
[[ "$onone" == rig_verdict=PASS ]] && ok "matrix-paychain hook: no DIFFRUN_ROLE -> no floor, no RESULT_JSON" || bad "matrix-paychain hook: rig-only run" "$onone"

# diag/wire.py: TCP reassembly, framing, validated resync, the unframed handshake, parsers (tests/wire_test.py)
if python3 tests/wire_test.py > "$T/wire.txt" 2>&1; then ok "wire.py: $(grep -oE 'Ran [0-9]+ tests' "$T/wire.txt")"
else bad "wire.py: reassembly and framing" "see $T/wire.txt"; fi
# diag/matrix_value.py: uncle duplicate/unique split, sibling fates, frame bytes, type-102 request matching (tests/matrix_value_test.py)
if python3 tests/matrix_value_test.py > "$T/matrix_value.txt" 2>&1; then ok "matrix_value.py: $(grep -oE 'Ran [0-9]+ tests' "$T/matrix_value.txt")"
else bad "matrix_value.py: value split and request matching" "see $T/matrix_value.txt"; fi

# diffrun/logab.sh: base vs candidate node logs (synthetic runs, no node): a line only the candidate logs is novel,
# identical logs give no novel message; one run per role is skipped by default (DIFFRUN_LOGAB_MIN=1 forces it)
mkrun(){ mkdir -p "$1/logs"; for i in $(seq 1 30); do echo "10:00:$(printf %02d $((i % 60))).000 INFO  [x] o.e.n.Foo - step $i done"; done > "$1/logs/node_A.log"; }
LA="$T/logab"; mkrun "$LA/runs/base-1"; mkrun "$LA/runs/candidate-1"
echo "10:01:00.000 WARN  [x] o.e.n.Bar - something new appeared" >> "$LA/runs/candidate-1/logs/node_A.log"
skip_msg="$(bash diffrun/logab.sh "$LA" 2>&1 >/dev/null)"
if [[ ! -e "$LA/logab_novelty.txt" && "$skip_msg" == *"1 base / 1 candidate runs; skipped"* ]]; then ok "logab.sh: one run per role -> skipped, says why, writes nothing"
else bad "logab.sh: one run per role -> skipped" "$skip_msg"; fi
DIFFRUN_LOGAB_MIN=1 bash diffrun/logab.sh "$LA" 2>/dev/null
if grep -q "something new appeared" "$LA/logab_novelty.txt" 2>/dev/null; then ok "logab.sh: a candidate-only line is novel (DIFFRUN_LOGAB_MIN=1)"
else bad "logab.sh: a candidate-only line is novel" "see $LA/logab_novelty.txt"; fi
LB="$T/logab-same"; mkrun "$LB/runs/base-1"; mkrun "$LB/runs/candidate-1"; DIFFRUN_LOGAB_MIN=1 bash diffrun/logab.sh "$LB" 2>/dev/null
if grep -q "new message" "$LB/logab_novelty.txt" 2>/dev/null; then bad "logab.sh: identical logs give no new message" "see $LB/logab_novelty.txt"
else ok "logab.sh: identical logs give no new message"; fi

# diffrun/aa_pool.py: pooled A/A rates with an exact interval (tests/aa_pool_test.py)
if python3 tests/aa_pool_test.py > "$T/aa_pool.txt" 2>&1; then ok "aa_pool.py: exact interval and pooling"
else bad "aa_pool.py: exact interval and pooling" "see $T/aa_pool.txt"; fi

# every diffrun manifest validates (run.sh rejects one that does not, before any run)
inval=""; for m in $(find diffrun/scenarios -name '*.json' | sort); do
  [[ "$(jq -r 'has("script") and has("expect")' "$m")" == true ]] || continue   # topologies under hooks/ are not manifests
  e="$(jq -L diffrun/lib -c 'include "diffrun"; validate_manifest' "$m")"; [[ "$e" == "[]" ]] || inval+="$m: $e; "; done
[[ -z "$inval" ]] && ok "diffrun manifests: all validate" || bad "diffrun manifests: all validate" "$inval"

# diffrun/pool.sh: one verdict over sharded run.sh outputs (tests/diffrun_pool.sh: synthetic shards, no node)
if T="$T/pool" bash tests/diffrun_pool.sh > "$T/pool.txt" 2>&1; then ok "pool.sh: $(grep ' ok$' "$T/pool.txt" | grep -vc '^pool tests') cases (verdicts, lost shards, refusals, falsifier)"
else bad "pool.sh: pooled verdict over shards" "see $T/pool.txt"; fi

fx proposed
out="$(PEERYARD_PATCHES_DIR="$T/patches" FX_CLONE="$R" TMPDIR="$T" bash patches/stack.sh fx 2>/dev/null)"
if [[ -f "$out" ]]; then
  W="$T/wt"; git -C "$R" worktree add -q --detach "$W" v1; git -C "$W" apply "$out"
  cmp -s "$W/a.txt" <(git -C "$R" show v2:a.txt) && ok "stack.sh: combined diff on v1 reproduces v2" || bad "stack.sh: combined diff on v1 reproduces v2" "content differs"
  git -C "$R" worktree remove --force "$W"
else bad "stack.sh: writes a combined diff" "no file: $out"; fi
expect_rc "stack.sh: --build refused for a folder not built by diffrun" 2 "$(PEERYARD_PATCHES_DIR="$T/patches" FX_CLONE="$R" bash patches/stack.sh --build fx > /dev/null 2>&1; echo $?)"

# ---- register.sh: a symlink to a jar that has a build sidecar
J="$T/jars"; mkdir -p "$J/cache"; printf 'jar' > "$J/cache/node.jar"
jq -n '{sidecar_schema_version: 1, kind: "build", expected_app_version: "9.9-1-abc-SNAPSHOT"}' > "$J/cache/node.jar.json"
ln -s "$J/cache/node.jar" "$J/b.jar"; printf 'rel' > "$J/r.jar"
expect_rc "register.sh: version omitted -> the build's version" 0 "$(bash diffrun/register.sh -f "$J/b.jar" 2>/dev/null; echo $?)"
[[ "$(jq -r .expected_app_version "$J/b.jar.json")" == 9.9-1-abc-SNAPSHOT ]] && ok "register.sh: ... sidecar says 9.9-1-abc-SNAPSHOT" || bad "register.sh: ... sidecar version" "$(jq -c . "$J/b.jar.json")"
expect_rc "register.sh: a different version is refused, even with -f" 2 "$(bash diffrun/register.sh -f "$J/b.jar" 9.9 2>/dev/null; echo $?)"
expect_rc "register.sh: --override-version registers it" 0 "$(bash diffrun/register.sh -f --override-version "$J/b.jar" 9.9 2>/dev/null; echo $?)"
expect_rc "register.sh: a plain jar with no version -> usage error" 2 "$(bash diffrun/register.sh "$J/r.jar" 2>/dev/null; echo $?)"
expect_rc "register.sh: a plain jar with a version" 0 "$(bash diffrun/register.sh "$J/r.jar" 6.0.6 2>/dev/null; echo $?)"

# ---- provenance.sh: the four forms
v="peeryard v$(tr -d '[:space:]' < VERSION)"
p0="$(bash review/provenance.sh)"; [[ "$p0" == "$v"* ]] && ok "provenance.sh: no jar -> '$v…'" || bad "provenance.sh: no jar" "$p0"
printf 'ref' > "$J/ref.jar"; jq -n '{base: "v6.0.6", patches: [{id: "001"}, {id: "002"}]}' > "$J/ref.jar.stack.json"
p1="$(bash review/provenance.sh "$J/ref.jar")"; [[ "$p1" == *"on reference node v6.0.6+001,002 ("* ]] && ok "provenance.sh: stack note -> reference node v6.0.6+001,002" || bad "provenance.sh: stack note" "$p1"
p2="$(bash review/provenance.sh "$J/cache/node.jar")"; [[ "$p2" == *"on 9.9-1-abc-SNAPSHOT ("* ]] && ok "provenance.sh: build sidecar -> its app version" || bad "provenance.sh: build sidecar" "$p2"
p3="$(bash review/provenance.sh "$J/r.jar" "$J/ref.jar")"; [[ "$p3" == *"on base "*" and candidate reference node "* ]] && ok "provenance.sh: two jars -> base … and candidate …" || bad "provenance.sh: two jars" "$p3"

# ---- agent-files.sh (--git): agent-instruction files and context dumps are flagged, source is not
g checkout -q --detach v1; mkdir -p "$R/.github/instructions" "$R/src/main"
printf -- '---\napplyTo: "**"\n---\nYou are an expert.\n' > "$R/.github/instructions/x.instructions.md"
printf 'rules\n' > "$R/AGENTS.md"; seq 1 6000 > "$R/dump.txt"; seq 1 6000 > "$R/src/main/Big.txt"; mkdir -p "$R/gradle"; seq 1 6000 > "$R/gradle/verification-metadata.xml"
g add -A; g commit -qm agent; g tag agent
af="$(bash review/agent-files.sh --git "$R" v1 agent)"; rc=$?
expect_rc "agent-files.sh: a commit with agent files -> exit 1" 1 "$rc"
grep -q "FLAG agent-instructions added +4 .github/instructions/x.instructions.md" <<< "$af" && ok "agent-files.sh: ... flags the Copilot instructions file" || bad "agent-files.sh: instructions file" "$af"
grep -q "FLAG agent-instructions added +1 AGENTS.md" <<< "$af" && ok "agent-files.sh: ... flags AGENTS.md" || bad "agent-files.sh: AGENTS.md" "$af"
grep -q "FLAG context-dump added +6000 dump.txt" <<< "$af" && ok "agent-files.sh: ... flags a 6000-line text dump" || bad "agent-files.sh: dump" "$af"
grep -q "verification-metadata.xml" <<< "$af" && bad "agent-files.sh: ... a large generated XML is not a dump" "flagged" || ok "agent-files.sh: ... a large generated XML is not a dump"
grep -q "src/main/Big.txt" <<< "$af" && bad "agent-files.sh: ... a large file under src/ is not a dump" "flagged" || ok "agent-files.sh: ... a large file under src/ is not a dump"
expect_rc "agent-files.sh: a clean commit range -> exit 0" 0 "$(bash review/agent-files.sh --git "$R" v1 v2 > /dev/null; echo $?)"

# ---- patches/mutate.sh: a mutant is one patch from the base; the removed text must occur exactly once
M="$T/mut"; mkdir -p "$M"
mut(){ bash patches/mutate.sh --clone "$R" --base v1 "$@" > "$M/out.txt" 2> "$M/err.txt"; echo $?; }
applied(){ local w="$M/wt-$1"; rm -rf "$w"; git -C "$R" worktree add -q --detach "$w" v1 && git -C "$w" apply "$2" && paste -sd' ' "$w/a.txt"; git -C "$R" worktree remove --force "$w"; }
expect_rc "mutate.sh: base alone, one occurrence -> exit 0" 0 "$(mut --file a.txt --remove two --insert deux --out "$M/m1.patch")"
[[ "$(applied m1 "$M/m1.patch")" == "one deux three" ]] && ok "mutate.sh: ... the mutant applies alone to the base" || bad "mutate.sh: m1" "$(applied m1 "$M/m1.patch")"
expect_in "mutate.sh: ... the record names the removed text" '"removed": "two"' "$M/m1.patch.mutation.json"
expect_rc "mutate.sh: base + candidate patch -> exit 0" 0 "$(mut --patch "$T/001.patch" --file a.txt --remove $'TWO\n' --out "$M/m2.patch")"
[[ "$(applied m2 "$M/m2.patch")" == "one three" ]] && ok "mutate.sh: ... one patch = the candidate and the mutation" || bad "mutate.sh: m2" "$(applied m2 "$M/m2.patch")"
expect_rc "mutate.sh: text absent from the candidate's tree -> exit 2" 2 "$(mut --patch "$T/001.patch" --file a.txt --remove two --out "$M/m3.patch")"
expect_rc "mutate.sh: text occurring twice -> exit 2" 2 "$(mut --file a.txt --remove o --out "$M/m4.patch")"
expect_in "mutate.sh: ... and says how many times" "occurs 2 times" "$M/err.txt"

# ---- rig/lib/blockwatch.sh against a stubbed REST API: blocks collected across a reorg, checked clean, then with the
# deliberately failing contract check reported on every block (BLOCKWATCH_RESULT, the value rig.sh judges)
BW="$T/bw"; mkdir -p "$BW/out"
bw_put(){ local h=$1 id=$2 par=$3; echo "$id" > "$BW/A.id.$h"; printf '{"header":{"id":"%s","height":%s,"parentId":"%s"},"blockTransactions":{"transactions":[{"id":"%s"}]}}' "$id" "$h" "$par" "$(printf 'c%063d' "$h")" > "$BW/blk.$id"; echo "$h" > "$BW/A.top"; }
bwid(){ printf '%s%063d' "$1" "$2"; }
( RIG_LOG_DIR="$BW/out"; BG_PIDS=(); export BLOCKWATCH_POLL_S=0.2 BLOCKWATCH_FROM=1
  full_height(){ cat "$BW/$1.top"; }; header_at(){ cat "$BW/$1.id.$2" 2>/dev/null; }; mempool_ids(){ :; }; mark(){ :; }
  rest(){ case "$2" in /info) printf '{"fullHeight":%s,"bestFullHeaderId":"%s"}' "$(cat "$BW/$1.top")" "$(cat "$BW/$1.id.$(cat "$BW/$1.top")")" ;;
                       /blocks/*) cat "$BW/blk.${2#/blocks/}" ;; esac; }
  # shellcheck source=rig/lib/blockwatch.sh
  source rig/lib/blockwatch.sh
  for h in 1 2 3 4 5; do bw_put "$h" "$(bwid a "$h")" "$( ((h > 1)) && bwid a $((h - 1)) || printf '%064d' 0)"; done
  blockwatch_start A > /dev/null; sleep 1.5
  bw_put 5 "$(bwid b 5)" "$(bwid a 4)"; bw_put 6 "$(bwid b 6)" "$(bwid b 5)"; sleep 1.5      # A switches to a sibling at 5
  blockwatch_stop > "$BW/clean.txt"; echo "rc=$? result=$BLOCKWATCH_RESULT" >> "$BW/clean.txt"
  blockwatch_stop --contract rig/lib/invariants/deliberate-fail.sh > "$BW/fail.txt"; echo "rc=$? result=$BLOCKWATCH_RESULT" >> "$BW/fail.txt" )
[[ $(grep -c '"h":5,"id"' "$BW/out/blocks.jsonl") == 2 ]] && ok "blockwatch.sh: both blocks at a reorged height recorded" || bad "blockwatch.sh: reorg" "$(grep -c '"h":5,"id"' "$BW/out/blocks.jsonl") block records at 5"
expect_in "blockwatch.sh: a clean chain -> OK" "rc=0 result=OK" "$BW/clean.txt"
expect_in "blockwatch.sh: deliberate-fail contract -> reported per block" "contract:deliberate-fail.sh A@5 b0000" "$BW/fail.txt"
expect_in "blockwatch.sh: ... and BLOCKWATCH_RESULT says VIOLATED" "rc=1 result=VIOLATED total=6" "$BW/fail.txt"

# ---- post.sh guard (a stub detector; the prompt is answered "no", so nothing is posted: exit 1 = reached the prompt)
P="$T/post"; mkdir -p "$P"
printf '#!/usr/bin/env bash\necho "FLAG agent-instructions added +609 .github/instructions/ins.instructions.md"\nexit 1\n' > "$P/flag.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$P/none.sh"; printf '#!/usr/bin/env bash\nexit 2\n' > "$P/err.sh"; chmod +x "$P"/*.sh
body(){ printf 'Review carried out by Claude (Anthropic, Claude Opus 5.5) for the maintainer, using peeryard v0.1.0 on x (0123456789ab); ran y.\n\n**Verdict line.**\n\n**[Integration] Drop an unrelated file**\n\nObserved: %s.\n\nRecommended: remove it. (read)\n' "$1"; }
body 'this diff adds `.github/instructions/ins.instructions.md`' > "$P/named.md"; body 'the fix is fine' > "$P/unnamed.md"
pst(){ printf 'no\n' | PEERYARD_AGENT_FILES_CMD="$P/$1.sh" bash review/post.sh o/r 1 "$P/$2.md" "${@:3}" > "$P/out-$1-$2.txt" 2>&1; echo $?; }
expect_rc "post.sh: flagged file named in the text -> reaches the prompt" 1 "$(pst flag named)"
expect_rc "post.sh: flagged file not named -> refused (exit 5)" 5 "$(pst flag unnamed)"
expect_rc "post.sh: ... --ack-agent-files -> reaches the prompt" 1 "$(pst flag unnamed --ack-agent-files)"
expect_rc "post.sh: detector lookup failed -> refused (exit 5)" 5 "$(pst err unnamed)"
expect_rc "post.sh: nothing flagged -> reaches the prompt" 1 "$(pst none unnamed)"

# ---- rig/suite-env.sh (sweep.yml's scenario_env): only keys an example's suite.tsv row declares, in that row only
S="$T/suite.tsv"
printf '# comment\tREORG_W=1\tx\ty\tz\nre\tRE: PASS\t900\tREORG_W=180 OTHER=1\t-\nre2\tRE2: PASS\t900\tREORG_W=180\t-\nplain\tPLAIN\t600\t-\t-\n' > "$S"
cp "$S" "$T/suite.orig"
se(){ bash rig/suite-env.sh "$S" "$@" > "$T/se.out" 2>&1; echo $?; }
expect_rc "suite-env.sh: empty override -> no change" 0 "$(se '' re)"
cmp -s "$S" "$T/suite.orig" && ok "suite-env.sh: ... file unchanged" || bad "suite-env.sh: ... file unchanged" "$(diff "$T/suite.orig" "$S")"
expect_rc "suite-env.sh: declared key, one named row" 0 "$(se 'REORG_W=600' re)"
[[ "$(cut -f4 "$S" | sed -n 2,3p | tr '\n' '|')" == 'REORG_W=600 OTHER=1|REORG_W=180|' ]] && ok "suite-env.sh: ... set in that row only, other words kept" \
  || bad "suite-env.sh: ... set in that row only" "$(cut -f4 "$S" | tr '\n' '|')"
[[ "$(head -1 "$S")" == "$(head -1 "$T/suite.orig")" ]] && ok "suite-env.sh: ... comment line untouched" || bad "suite-env.sh: comment" "$(head -1 "$S")"
cp "$T/suite.orig" "$S"
expect_rc "suite-env.sh: no names -> every declaring row" 0 "$(se 'REORG_W=600')"
[[ "$(grep -c 'REORG_W=600' "$S")" == 2 ]] && ok "suite-env.sh: ... both rows set" || bad "suite-env.sh: both rows" "$(cut -f4 "$S" | tr '\n' '|')"
cp "$T/suite.orig" "$S"
expect_rc "suite-env.sh: key no named row declares -> exit 1" 1 "$(se 'REORG_W=600' plain)"
expect_rc "suite-env.sh: undeclared key -> exit 1" 1 "$(se 'NOPE=1' re)"
expect_rc "suite-env.sh: unknown example -> exit 1" 1 "$(se 'REORG_W=600' nosuch)"
expect_rc "suite-env.sh: value with a space -> exit 1" 1 "$(se 'REORG_W=6 00' re)"
expect_rc "suite-env.sh: value with a shell metacharacter -> exit 1" 1 "$(se 'REORG_W=$(id)' re)"
cmp -s "$S" "$T/suite.orig" && ok "suite-env.sh: ... refused overrides leave the file unchanged" || bad "suite-env.sh: refused overrides" "$(diff "$T/suite.orig" "$S")"
expect_rc "suite-env.sh: the repository's reorg rows declare REORG_CONFIRM_WAIT_S" 0 \
  "$(cp rig/examples/suite.tsv "$T/real.tsv"; bash rig/suite-env.sh "$T/real.tsv" 'REORG_CONFIRM_WAIT_S=600' reorg-mempool reorg-mempool-phases > "$T/se.out" 2>&1; echo $?)"

# ---- fork-convergence's follower state (pr-scenario.yml's scenario_env reaches only keys the manifest declares):
# FC_FOLLOWER_STATE is declared in both manifests with the default utxo, and the script refuses any other value than
# utxo or digest before it starts a namespace or a node
for m in fork-convergence fork-convergence-smoke; do
  [[ "$(jq -r '.env.FC_FOLLOWER_STATE' "diffrun/scenarios/$m.json")" == utxo ]] && ok "$m.json: FC_FOLLOWER_STATE declared, default utxo" \
    || bad "$m.json: FC_FOLLOWER_STATE" "$(jq -c .env "diffrun/scenarios/$m.json")"
  cp "diffrun/scenarios/$m.json" "$T/fc.json"
  expect_rc "scenario-env.sh: $m FC_FOLLOWER_STATE=digest" 0 "$(bash diffrun/scenario-env.sh "$T/fc.json" 'FC_FOLLOWER_STATE=digest' > "$T/se.out" 2>&1; echo $?)"
  [[ "$(jq -r '.env.FC_FOLLOWER_STATE' "$T/fc.json")" == digest ]] && ok "scenario-env.sh: ... $m env now digest" || bad "scenario-env.sh: $m env" "$(jq -c .env "$T/fc.json")"
  for k in l_digest_rollbacks s_digest_rollbacks l_utxo_rollbacks s_utxo_rollbacks l_rollback_failed s_rollback_failed; do
    [[ "$(jq -r --arg k "$k" '.metrics[$k]' "diffrun/scenarios/$m.json")" == number ]] || bad "$m.json: metric $k" "not declared as a number"; done
done
printf x > "$T/fc.jar"
expect_rc "fork-convergence.sh: FC_FOLLOWER_STATE=pruned -> exit 2" 2 "$(FC_FOLLOWER_STATE=pruned WORKDIR="$T/fcw" bash diffrun/scenarios/fork-convergence.sh "$T/fc.jar" > "$T/fc.out" 2>&1; echo $?)"
expect_in "fork-convergence.sh: ... says why" "FC_FOLLOWER_STATE must be utxo or digest" "$T/fc.out"
[[ ! -e "$T/fcw" ]] && ok "fork-convergence.sh: ... before any WORKDIR is made" || bad "fork-convergence.sh: refused value" "WORKDIR $T/fcw was created"

[[ $fail == 0 ]] && echo "tooling tests: all ok" || { echo "tooling tests: MISMATCH (see $T)"; exit 1; }
