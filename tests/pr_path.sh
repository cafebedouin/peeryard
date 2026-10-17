#!/usr/bin/env bash
# pr_path.sh: tests review/pr-line.sh (the pr-scenario line for a pull request) on a throwaway git history with a local
# "origin" and a recorded API reply, and the rig-example scenario (diffrun/scenarios/rig-example.*, lib/rig-scenario.sh,
# diffrun/scenario-check.sh): which suite examples it runs, its dispatch-time check, and run.sh end to end on a stub
# rig (no namespaces, no nodes). No network, no JDK. Run from the peeryard root:
#   T=$(mktemp -d) bash tests/pr_path.sh
set -uo pipefail
miss=(); for t in git jq timeout; do command -v "$t" >/dev/null 2>&1 || miss+=("$t"); done
[[ ${#miss[@]} -eq 0 ]] || { echo "tests/pr_path.sh needs ${miss[*]}; not run" >&2; exit 2; }
T="${T:?set T to a scratch dir, e.g. T=$(mktemp -d)}"
# T is deleted and recreated below: refuse anything that is not a scratch dir under /tmp or $TMPDIR (where
# mktemp -d puts one), and anything that contains the current directory (T=. from the repo root).
Tr="$(realpath -m -- "$T")"; Tmpr="$(realpath -m -- "${TMPDIR:-/tmp}")"
case "$Tr/" in /tmp/?*/|"$Tmpr"/?*/) ;; *) echo "refusing T='$T': not a scratch dir under /tmp or \$TMPDIR (use T=\$(mktemp -d))" >&2; exit 2 ;; esac
case "$PWD/" in "$Tr"/*) echo "refusing T='$T': it contains the current directory" >&2; exit 2 ;; esac
rm -rf "$T"; mkdir -p "$T"
ROOT="$PWD"; fail=0
ok(){ printf '%-72s ok\n' "$1"; }
bad(){ printf '%-72s MISMATCH (%s)\n' "$1" "$2"; fail=1; }
expect_rc(){ [[ "$3" == "$2" ]] && ok "$1" || bad "$1" "want exit $2, got $3"; }
expect_eq(){ [[ "$3" == "$2" ]] && ok "$1" || bad "$1" "want '$2', got '$3'"; }
expect_in(){ grep -qF -- "$2" "$3" && ok "$1" || bad "$1" "no '$2' in $3"; }

# ===== review/pr-line.sh =====
# The history (S = upstream, a bare repository served as "origin"):
#   master   c0 - c1 (v1.0.0, annotated) - cA - c2 (v1.0.1)
#   v1.0.2   c2 - c3 - M (merge of side, from c2) - c4         the release branch PRs target; M is untagged
#   PRs      #11 on c2, #12 on M, #13 on cA (diff applies on v1.0.1), #14 on cA (collides with c2), #15 on c1,
#            #19 criss-cross with xb (two merge bases), #17/#18 on weak-blocks (w1 = the carried commit, w2 newer)
S="$T/upstream.git"; W="$T/work"; git init -q --bare "$S"; git init -q "$W"
g(){ git -C "$W" -c user.name=t -c user.email=t@t -c commit.gpgsign=false -c tag.gpgsign=false "$@"; }
put(){ mkdir -p "$W/$(dirname "$1")"; printf '%s\n' "$2" > "$W/$1"; g add "$1"; g commit -q -m "$3"; }
put src/main/a.scala a0 c0; put src/main/c.scala c0 c0b
put src/main/b.scala b1 c1; g tag -a v1.0.0 -m v1.0.0; c1="$(g rev-parse HEAD)"
put src/main/b.scala b2 cA; cA="$(g rev-parse HEAD)"
put src/main/c.scala c2 c2; g tag v1.0.1; c2="$(g rev-parse HEAD)"
g branch -q -m master
g checkout -q -b side "$c2"; put src/main/e.scala e1 side1
g checkout -q -b v1.0.2 "$c2"; put src/main/d.scala d3 c3
g -c core.editor=true merge -q --no-ff side -m M; M="$(g rev-parse HEAD)"
put src/main/f.scala f4 c4
pr(){ local n="$1" from="$2" f="$3" v="$4"; g checkout -q -b "p$n" "$from"; put "$f" "$v" "pr $n"; g update-ref "refs/pull/$n/head" HEAD; }
pr 11 "$c2" src/main/a.scala a11; pr 12 "$M" src/main/a.scala a12; pr 13 "$cA" src/main/a.scala a13
pr 14 "$cA" src/main/c.scala c14; pr 15 "$c1" src/main/a.scala a15
# criss-cross: xb gets x1 (two files), the PR p1 (one file); xb merges p1, the PR merges x1: merge bases {x1, p1}
g checkout -q -b xb "$c2"; put src/main/x.scala x1 x1a; put src/main/y.scala y1 x1b; x1="$(g rev-parse HEAD)"
g checkout -q -b p19 "$c2"; put src/main/a.scala a19 p1; p1="$(g rev-parse HEAD)"
g checkout -q xb; g -c core.editor=true merge -q --no-ff p19 -m xm
g checkout -q p19; g -c core.editor=true merge -q --no-ff "$x1" -m pm; g update-ref refs/pull/19/head HEAD
# weak-blocks: w1 is the commit peeryard carries, w2 is newer
g checkout -q -b weak-blocks "$c2"; put src/main/w.scala w1 w1; w1="$(g rev-parse HEAD)"; put src/main/w.scala w2 w2; w2="$(g rev-parse HEAD)"
pr 17 "$w1" src/main/a.scala a17; pr 18 "$w2" src/main/a.scala a18
g push -q "$S" master v1.0.2 xb weak-blocks 'refs/pull/*:refs/pull/*' --tags
C="$T/clone"; git clone -q "$S" "$C"
# the tree pr-line.sh runs from (its patches/ergo-matrix/patches.json names the carried weak-blocks commit)
P="$T/py"; mkdir -p "$P/review" "$P/patches/ergo-matrix"; cp review/pr-line.sh "$P/review/"
jq -n --arg b "$w1" '{base: $b}' > "$P/patches/ergo-matrix/patches.json"
# the API reply: the recorded shape of GET /repos/ergoplatform/ergo/pulls/2421 (tests/fixtures/pr-line/), with this
# history's base branch and head
api(){ jq --arg n "$1" --arg b "$2" --arg h "$3" '.number = ($n | tonumber) | .base.ref = $b | .head.sha = $h' tests/fixtures/pr-line/pull-2421.json > "$T/pull-$1.json"; }
line(){ local n="$1" b="$2"; shift 2; api "$n" "$b" "$(g rev-parse "refs/pull/$n/head")"
  bash "$P/review/pr-line.sh" --pr "$n" --clone "$C" --pr-json "$T/pull-$n.json" "$@" > "$T/line-$n$*.txt" 2>&1; echo $?; }
last(){ tail -1 "$T/line-$1.txt"; }

expect_rc "pr-line: PR on a tagged commit -> exit 0" 0 "$(line 11 v1.0.2 --line-only)"
expect_eq "pr-line: ... line = the release tag at the merge base" v1.0.1 "$(last "11--line-only")"
expect_rc "pr-line: PR on the release branch's untagged merge commit" 0 "$(line 12 v1.0.2 --line-only)"
expect_eq "pr-line: ... line = the merge base, 40 hex (not the branch name)" "$M" "$(last "12--line-only")"
expect_rc "pr-line: PR on an annotated tag" 0 "$(line 15 v1.0.2 --line-only)"
expect_eq "pr-line: ... line = that tag" v1.0.0 "$(last "15--line-only")"
expect_rc "pr-line: PR on an untagged commit below a release" 0 "$(line 13 v1.0.2 --line-only)"
expect_eq "pr-line: ... default: the exact merge base" "$cA" "$(last "13--line-only")"
line 13 v1.0.2 --line-only --prefer-release > /dev/null
expect_eq "pr-line: ... --prefer-release: the newest release that takes the diff" v1.0.1 "$(last "13--line-only --prefer-release")"
expect_in "pr-line: ... and says the base arm is that release" "the base arm is v1.0.1" "$T/line-13--line-only --prefer-release.txt"
line 14 v1.0.2 --line-only --prefer-release > /dev/null
expect_eq "pr-line: --prefer-release when the diff collides: the exact merge base" "$cA" "$(last "14--line-only --prefer-release")"
line 11 v1.0.2 --line-only --prefer-release > /dev/null
expect_eq "pr-line: --prefer-release on a tagged merge base: the newest release" v1.0.1 "$(last "11--line-only --prefer-release")"
expect_rc "pr-line: criss-cross history (two merge bases)" 0 "$(line 19 xb --line-only)"
expect_eq "pr-line: ... the merge base with the smallest diff to the head" "$x1" "$(last "19--line-only")"
expect_rc "pr-line: weak-blocks PR on the carried commit" 0 "$(line 17 weak-blocks --line-only)"
expect_eq "pr-line: ... line = matrix" matrix "$(last "17--line-only")"
expect_rc "pr-line: weak-blocks PR newer than the carried commit -> exit 3" 3 "$(line 18 weak-blocks --line-only)"
expect_in "pr-line: ... says why" "newer than the weak-blocks commit peeryard carries" "$T/line-18--line-only.txt"
expect_rc "pr-line: base branch gone -> exit 3" 3 "$(line 11 gone-branch --line-only)"
expect_in "pr-line: ... points at patch mode" "patch mode" "$T/line-11--line-only.txt"
api 12 v1.0.2 "$(g rev-parse v1.0.2)"   # an API head that is not what pull/12/head holds
bash "$P/review/pr-line.sh" --pr 12 --clone "$C" --pr-json "$T/pull-12.json" > "$T/line-moved.txt" 2>&1
expect_rc "pr-line: the API head differs from pull/N/head -> exit 4" 4 "$?"
line 12 v1.0.2 --scenario rig-example --shards 1 --pairs 1 --scenario-env 'RIG_EXAMPLE=reorg-mempool' > /dev/null
f="$T/line-12--scenario rig-example --shards 1 --pairs 1 --scenario-env RIG_EXAMPLE=reorg-mempool.txt"
expect_eq "pr-line: the dispatch command, head as read and the line" \
  "gh workflow run pr-scenario.yml -R cafebedouin/peeryard --ref main -f pr=12 -f head=$(g rev-parse refs/pull/12/head) -f line=$M -f scenario=rig-example -f shards=1 -f pairs=1 -f 'scenario_env=RIG_EXAMPLE=reorg-mempool'" "$(tail -1 "$f")"
expect_rc "pr-line: a scenario_env with a quote -> usage error" 2 "$(bash "$P/review/pr-line.sh" --pr 12 --clone "$C" --pr-json "$T/pull-12.json" --scenario-env "A='x'" > /dev/null 2>&1; echo $?)"
# the production paths: the same four as pr-scenario.yml's build step
expect_eq "pr-line: PATHS equal pr-scenario.yml's" "$(grep -oE 'PATHS=\([^)]*\)' .github/workflows/pr-scenario.yml)" "$(grep -oE '^PATHS=\([^)]*\)' review/pr-line.sh)"

# ===== the rig-example scenario =====
X=diffrun/scenarios/rig-example.check.sh
bash "$X" --list > "$T/list.txt"
for n in reorg-mempool mempool-evict utxo-bootstrap nipopow-bootstrap corruption churn mining blockwatch bringup wallet-oracle-restart; do
  expect_eq "rig-example --list: $n runnable" runnable "$(awk -F'\t' -v n="$n" '$1 == n { print $2 }' "$T/list.txt")"; done
expect_eq "rig-example --list: matrix-pair runnable on the Matrix line" "runnable (Matrix line)" "$(awk -F'\t' '$1 == "matrix-pair" { print $2 }' "$T/list.txt")"
for n in mixed matrix-mixed matrix-compat-1m3r arkadianet-follow ergo-node-rust-follow; do
  expect_in "rig-example --list: $n refused" "$(printf '%s\trefused: ' "$n")" "$T/list.txt"; done
expect_eq "rig-example --list: one row per suite example" "$(awk -F'\t' '!/^#/ && NF == 5' rig/examples/suite.tsv | wc -l)" "$(wc -l < "$T/list.txt")"
chk(){ env "$@" bash "$X" > "$T/chk.txt" 2>&1; echo $?; }
expect_rc "rig-example check: RIG_EXAMPLE unset -> 1" 1 "$(chk RIG_EXAMPLE=)"
expect_rc "rig-example check: unknown example -> 1" 1 "$(chk RIG_EXAMPLE=no-such)"
expect_rc "rig-example check: a refused example -> 1" 1 "$(chk RIG_EXAMPLE=mixed)"
expect_rc "rig-example check: reorg-mempool -> 0" 0 "$(chk RIG_EXAMPLE=reorg-mempool)"
expect_in "rig-example check: ... with its suite env" "REORG_CONFIRM_WAIT_S=180" "$T/chk.txt"
expect_rc "rig-example check: a declared key overridden -> 0" 0 "$(chk RIG_EXAMPLE=reorg-mempool 'RIG_EXAMPLE_ENV=REORG_CONFIRM_WAIT_S:600')"
expect_in "rig-example check: ... the override in effect" "REORG_CONFIRM_WAIT_S=600" "$T/chk.txt"
expect_rc "rig-example check: an undeclared key -> 1" 1 "$(chk RIG_EXAMPLE=reorg-mempool 'RIG_EXAMPLE_ENV=NOT_A_KEY:1')"
expect_rc "rig-example check: an item without ':' -> 1" 1 "$(chk RIG_EXAMPLE=reorg-mempool 'RIG_EXAMPLE_ENV=REORG_CONFIRM_WAIT_S=600')"
expect_rc "rig-example check: a Matrix example on a release line -> 1" 1 "$(chk RIG_EXAMPLE=matrix-pair DIFFRUN_LINE=v6.0.8)"
expect_rc "rig-example check: a Matrix example on line=matrix -> 0" 0 "$(chk RIG_EXAMPLE=matrix-pair DIFFRUN_LINE=matrix)"
# diffrun/scenario-check.sh: the manifest's effective env (after scenario-env.sh), and a scenario with no check passes
cp diffrun/scenarios/rig-example.json "$T/rx.json"; bash diffrun/scenario-env.sh "$T/rx.json" 'RIG_EXAMPLE=churn' > /dev/null
expect_rc "scenario-check: rig-example with RIG_EXAMPLE=churn -> 0" 0 "$(DIFFRUN_LINE=v6.0.8 bash diffrun/scenario-check.sh "$T/rx.json" > /dev/null 2>&1; echo $?)"
expect_rc "scenario-check: rig-example as shipped (RIG_EXAMPLE empty) -> 1" 1 "$(bash diffrun/scenario-check.sh diffrun/scenarios/rig-example.json > /dev/null 2>&1; echo $?)"
expect_rc "scenario-check: a scenario with no check (interop) -> 0" 0 "$(bash diffrun/scenario-check.sh diffrun/scenarios/interop.json > /dev/null 2>&1; echo $?)"
expect_eq "rig-example manifest validates" "[]" "$(jq -c -L diffrun/lib 'include "diffrun"; validate_manifest' diffrun/scenarios/rig-example.json)"

# run.sh end to end on a stub rig: the tree is this diffrun/ beside a rig/ whose rig.sh sources the hook with stub
# helpers, and whose suite holds five examples (pass, fail, timeout, inconclusive, no marker)
Y="$T/tree"; mkdir -p "$Y/rig/examples"; cp -r diffrun "$Y/"; cp rig/suite-env.sh "$Y/rig/"
cat > "$Y/rig/rig.sh" <<'EOF'
#!/usr/bin/env bash
# stub rig.sh (tests/pr_path.sh): no namespaces and no nodes; the hook runs with rest() answering /info
set -uo pipefail
CFG="$1"; HOOK="$2"; mapfile -t NODES < <(jq -r '.nodes[].name' "$CFG"); mkdir -p "$SCRATCH"; echo "[rig] scratch: $SCRATCH"
rest(){ [[ "$2" == /info ]] && printf '{"appVersion":"%s"}' "${STUB_APP_VERSION:-0.0.1}"; }
# shellcheck disable=SC1090
source "$HOOK"
echo "[rig] === hook done (verdict: ${rig_verdict:-none}) ==="
[[ "${rig_verdict:-}" == FAIL ]] && exit 1
[[ "${rig_verdict:-}" == INCONCLUSIVE ]] && exit 3
exit 0
EOF
for n in okx failx slowx brokenx nomarkx; do echo '{"nodes": [{"name": "A"}, {"name": "B"}], "links": [{"a": "A", "b": "B"}]}' > "$Y/rig/examples/$n.json"; done
echo 'echo "[okx] HOOK=$HOOK K=$OKX_K"; echo "OKX: PASS"; rig_verdict=PASS' > "$Y/rig/examples/okx.sh"
echo 'echo "FAILX: FAIL"; rig_verdict=FAIL' > "$Y/rig/examples/failx.sh"
echo 'sleep 30; echo "SLOWX: PASS"; rig_verdict=PASS' > "$Y/rig/examples/slowx.sh"
echo 'echo "[rig] CAUSE (hook) SETUP_FLOOR"; rig_verdict=INCONCLUSIVE' > "$Y/rig/examples/brokenx.sh"
echo 'echo "NOMARKX: done"; rig_verdict=PASS' > "$Y/rig/examples/nomarkx.sh"
printf '%s\n' '# name marker timeout env needs' $'okx\tOKX: PASS\t60\tOKX_K=1\t-' $'failx\tFAILX: PASS\t60\t-\t-' \
  $'slowx\tSLOWX: PASS\t2\t-\t-' $'brokenx\tBROKENX: PASS\t60\t-\t-' $'nomarkx\tNOMARKX: PASS\t60\t-\t-' > "$Y/rig/examples/suite.tsv"
printf x > "$T/j.jar"; bash diffrun/register.sh -f "$T/j.jar" 0.0.1 > /dev/null 2>&1
rx(){ local name="$1" over="$2" o="$3"; shift 3; local m="$Y/diffrun/scenarios/rx-$name.json"
  cp "$Y/diffrun/scenarios/rig-example.json" "$m"; bash diffrun/scenario-env.sh "$m" "RIG_EXAMPLE=$name${over:+;$over}" > /dev/null
  jq '.n = 1' "$m" > "$m.t" && mv "$m.t" "$m"
  env PEERYARD_JAVA=true DIFFRUN_LOGAB=0 "$@" bash "$Y/diffrun/run.sh" "$m" --base "$T/j.jar" --candidate "$T/j.jar" --out "$T/o-$o" > "$T/run-$o.log" 2>&1; echo $?; }
v(){ jq -r "$2" "$T/o-$1/verdict.json" 2>/dev/null; }
expect_rc "rig-example run: okx (A/A) -> verdict written" 0 "$(rx okx 'RIG_EXAMPLE_ENV=OKX_K:7' okx)"
expect_eq "rig-example run: ... both runs VALID, pass true" "VALID:true:false:0 VALID:true:false:0" "$(v okx '[.runs[] | "\(.class):\(.metrics.pass):\(.metrics.timed_out):\(.metrics.rig_exit)"] | join(" ")')"
expect_eq "rig-example run: ... versions from every node" '{"A":"0.0.1","B":"0.0.1"}' "$(v okx '.runs[0].versions | tojson')"
expect_eq "rig-example run: ... verdict SUPPORTS (an A/A: same_jar)" "SUPPORTS:true" "$(v okx '"\(.verdict):\(.same_jar)"')"
expect_in "rig-example run: ... the example's hook ran as HOOK, with the override" "[okx] HOOK=$Y/rig/examples/okx.sh K=7" "$T/o-okx/runs/base-1/stdout.txt"
expect_rc "rig-example run: failx -> verdict written" 0 "$(rx failx '' failx)"
expect_eq "rig-example run: ... pass false, rig exit 1, AGAINST" "VALID:false:1 AGAINST" "$(v failx '"\(.runs[0].class):\(.runs[0].metrics.pass):\(.runs[0].metrics.rig_exit) \(.verdict)"')"
expect_rc "rig-example run: nomarkx (rig exit 0, marker absent) -> verdict written" 0 "$(rx nomarkx '' nomarkx)"
expect_eq "rig-example run: ... pass false (run-suite's PASS needs the marker)" "VALID:false:0" "$(v nomarkx '"\(.runs[0].class):\(.runs[0].metrics.pass):\(.runs[0].metrics.rig_exit)"')"
expect_rc "rig-example run: slowx (suite timeout 2 s) -> verdict written" 0 "$(rx slowx '' slowx)"
expect_eq "rig-example run: ... pass false, timed_out true" "VALID:false:true" "$(v slowx '"\(.runs[0].class):\(.runs[0].metrics.pass):\(.runs[0].metrics.timed_out)"')"
expect_rc "rig-example run: brokenx (rig exit 3) -> verdict written" 0 "$(rx brokenx '' brokenx)"
expect_eq "rig-example run: ... INCONCLUSIVE (setup), the hook's cause, DEGENERATE" "INCONCLUSIVE:setup:SETUP_FLOOR DEGENERATE" "$(v brokenx '"\(.runs[0].class):\(.runs[0].reason):\(.runs[0].cause) \(.verdict)"')"
expect_rc "rig-example run: okx, nodes report another appVersion" 0 "$(rx okx '' okx-void STUB_APP_VERSION=9.9.9)"
expect_eq "rig-example run: ... VOID (version-mismatch)" "VOID:version-mismatch" "$(v okx-void '"\(.runs[0].class):\(.runs[0].reason)"')"
# run_rig_scenario (the library's first entry point, shared with rig_scenario_launch): a stub scenario whose hook prints
# its own RESULT_JSON, as interop's does; and one whose hook prints none (INCONCLUSIVE)
echo '{"nodes": [{"name": "A"}]}' > "$Y/diffrun/scenarios/hooks/stubrs.json"
echo 'echo "RESULT_JSON {\"schema_version\":1,\"scenario\":\"stubrs\",\"versions\":{\"A\":\"$(rest A /info | jq -r .appVersion)\"},\"metrics\":{\"ok\":true}}"; rig_verdict=PASS' > "$Y/diffrun/scenarios/hooks/stubrs.sh"
echo 'rig_verdict=PASS' > "$Y/diffrun/scenarios/hooks/stubrs-none.sh"
for k in stubrs stubrs-none; do
  printf '%s\n' '#!/usr/bin/env bash' 'source "$(dirname "${BASH_SOURCE[0]}")/lib/rig-scenario.sh"' \
    "run_rig_scenario \"\$(dirname \"\${BASH_SOURCE[0]}\")/hooks/stubrs.json\" \"\$(dirname \"\${BASH_SOURCE[0]}\")/hooks/$k.sh\" \"\$1\"" > "$Y/diffrun/scenarios/$k.sh"
  jq -n --arg s "$k.sh" '{name: "stubrs", script: $s, tier: "public", env: {}, metrics: {ok: "boolean"}, n: 1, timeout_seconds: 60,
    expect: {base: {all: {key: "ok", op: "==", value: true}}, candidate: {all: {key: "ok", op: "==", value: true}}}}' > "$Y/diffrun/scenarios/$k.json"
  PEERYARD_JAVA=true DIFFRUN_LOGAB=0 bash "$Y/diffrun/run.sh" "$Y/diffrun/scenarios/$k.json" --base "$T/j.jar" --candidate "$T/j.jar" --out "$T/o-$k" > "$T/run-$k.log" 2>&1
done
expect_eq "run_rig_scenario: the hook's RESULT_JSON forwarded -> VALID, SUPPORTS" "VALID SUPPORTS" "$(v stubrs '"\(.runs[0].class) \(.verdict)"')"
expect_eq "run_rig_scenario: no RESULT_JSON -> INCONCLUSIVE (setup)" "INCONCLUSIVE:setup" "$(v stubrs-none '"\(.runs[0].class):\(.runs[0].reason)"')"

[[ $fail == 0 ]] && echo "pr_path tests: all ok" || { echo "pr_path tests: MISMATCH (see $T)"; exit 1; }
