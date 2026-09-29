#!/usr/bin/env bash
# tooling.sh: tests patches/check.sh, patches/stack.sh, diffrun/register.sh, diffrun/pool.sh and review/provenance.sh on local
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

# diffrun/logab.sh: base vs candidate node logs (synthetic runs, no node): a line only the candidate logs is novel,
# identical logs give no novel message
mkrun(){ mkdir -p "$1/logs"; for i in $(seq 1 30); do echo "10:00:$(printf %02d $((i % 60))).000 INFO  [x] o.e.n.Foo - step $i done"; done > "$1/logs/node_A.log"; }
LA="$T/logab"; mkrun "$LA/runs/base-1"; mkrun "$LA/runs/candidate-1"
echo "10:01:00.000 WARN  [x] o.e.n.Bar - something new appeared" >> "$LA/runs/candidate-1/logs/node_A.log"
bash diffrun/logab.sh "$LA" 2>/dev/null
if grep -q "something new appeared" "$LA/logab_novelty.txt" 2>/dev/null; then ok "logab.sh: a candidate-only line is novel"
else bad "logab.sh: a candidate-only line is novel" "see $LA/logab_novelty.txt"; fi
LB="$T/logab-same"; mkrun "$LB/runs/base-1"; mkrun "$LB/runs/candidate-1"; bash diffrun/logab.sh "$LB" 2>/dev/null
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

[[ $fail == 0 ]] && echo "tooling tests: all ok" || { echo "tooling tests: MISMATCH (see $T)"; exit 1; }
