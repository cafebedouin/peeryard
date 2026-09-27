#!/usr/bin/env bash
# precheck.sh: tests the precheck gate on the no-node stubs diffrun/scenarios/test/precheck-replay.json (the
# seq-replay script under test/precheck-stub.sh). Each case sets the stub's behavior per jar through <jar>.precheck.
# A failed or timed-out precheck must make that run INCONCLUSIVE (setup) without running the scenario; a passing
# one must leave the run untouched. No nodes, well under a minute. Run from the peeryard root:
#   T=$(mktemp -d) bash tests/precheck.sh
set -uo pipefail
T="${T:?set T to a scratch dir, e.g. T=$(mktemp -d)}"
# T is deleted and recreated below: refuse anything that is not a scratch dir under /tmp or $TMPDIR (where
# mktemp -d puts one), and anything that contains the current directory (T=. from the repo root).
Tr="$(realpath -m -- "$T")"; Tmpr="$(realpath -m -- "${TMPDIR:-/tmp}")"
case "$Tr/" in /tmp/?*/|"$Tmpr"/?*/) ;; *) echo "refusing T='$T': not a scratch dir under /tmp or \$TMPDIR (use T=\$(mktemp -d))" >&2; exit 2 ;; esac
case "$PWD/" in "$Tr"/*) echo "refusing T='$T': it contains the current directory" >&2; exit 2 ;; esac
rm -rf "$T"; mkdir -p "$T"
M=diffrun/scenarios/test/precheck-replay.json
jq 'del(.precheck, .precheck_timeout_seconds)' "$M" > "$T/noprecheck.json"
fail=0
say(){ [[ "$2" == "$3" ]] && r=ok || { r=MISMATCH; fail=1; }; printf '%-12s %-34s want [%s]  got [%s]  %s\n' "$1" "$4" "$3" "$2" "$r"; }
run(){ local name=$1 man=$2 bpre=$3 cpre=$4
  printf TT > "$T/$name-b.jar"; printf TT > "$T/$name-c.jar"
  printf %s "$bpre" > "$T/$name-b.jar.precheck"; printf %s "$cpre" > "$T/$name-c.jar.precheck"
  bash diffrun/register.sh -f "$T/$name-b.jar" 1 2>/dev/null; bash diffrun/register.sh -f "$T/$name-c.jar" 1 2>/dev/null
  bash diffrun/run.sh "$man" --base "$T/$name-b.jar" --candidate "$T/$name-c.jar" --out "$T/o-$name" > "$T/$name.log" 2>&1
  echo "rc=$?" >> "$T/$name.log"; V="$T/o-$name/verdict.json"; }
classes(){ jq -r --arg r "$1" '[.runs[] | select(.role == $r) | .class + (if .reason then "(" + .reason + ")" else "" end) + (if .precheck then "/" + .precheck else "" end)] | join(" ")' "$V"; }
count(){ cat "$1" 2>/dev/null || echo 0; }

# 1. both prechecks pass: nothing changes except the record
run pass "$M" pass pass
say pass "$(jq -r .verdict "$V")" SUPPORTS "verdict"
say pass "$(classes candidate)" "VALID/pass VALID/pass" "candidate classes"
say pass "$(jq -c .precheck "$V")" '{"script":"test/precheck-stub.sh","failed":0}' "verdict.precheck"
say pass "$(count "$T/pass-c.jar.precheck.count")/$(count "$T/pass-c.jar.count")" "2/2" "precheck calls/scenario calls (cand)"

# 2. the candidate's precheck fails: its runs are INCONCLUSIVE (setup), the scenario never runs, verdict DEGENERATE
run cfail "$M" pass fail
say cfail "$(jq -r .verdict "$V")" DEGENERATE "verdict"
say cfail "$(classes base)" "VALID/pass VALID/pass" "base classes"
say cfail "$(classes candidate)" "INCONCLUSIVE(setup)/fail INCONCLUSIVE(setup)/fail" "candidate classes"
say cfail "$(count "$T/cfail-c.jar.precheck.count")/$(count "$T/cfail-c.jar.count")" "2/0" "precheck calls/scenario calls (cand)"
say cfail "$(jq -r .detail "$T/o-cfail/runs/candidate-1/metadata.json")" "precheck failed: INCONCLUSIVE: precheck stub says fail" "metadata detail"
say cfail "$(jq -c '.precheck | {outcome, exit_code, fast: (.elapsed_s <= 1)}' "$T/o-cfail/runs/candidate-1/metadata.json")" '{"outcome":"fail","exit_code":3,"fast":true}' "metadata precheck"
say cfail "$(grep -c 'setup: precheck' "$T/o-cfail/table.txt")" 2 "table marks precheck failures"

# 3. the candidate's precheck hangs: the precheck timeout (3 s) kills it, and the run is INCONCLUSIVE (setup)
run chang "$M" pass hang
say chang "$(jq -r .verdict "$V")" DEGENERATE "verdict"
say chang "$(classes candidate)" "INCONCLUSIVE(setup)/fail INCONCLUSIVE(setup)/fail" "candidate classes"
say chang "$(jq -r '"\(.precheck.exit_code) \(.timed_out)"' "$T/o-chang/runs/candidate-1/metadata.json")" "124 true" "timed out"
say chang "$(count "$T/chang-c.jar.count")" 0 "scenario calls (cand)"

# 4. no precheck declared: the record says so and nothing runs before the scenario
run none "$T/noprecheck.json" fail fail
say none "$(jq -r .verdict "$V")" SUPPORTS "verdict"
say none "$(jq -c '[.precheck, .runs[0].precheck]' "$V")" '[null,null]' "verdict.precheck, run precheck"
say none "$(count "$T/none-c.jar.precheck.count")" 0 "precheck calls (cand)"

# 6. a scenario that ends INCONCLUSIVE with a cause code: the code reaches runs (verdict.json) and the table; free text
#    stays out of verdict.json; a malformed code is dropped
printf 'SETUP_PREFIX_RACE' > "$T/cause-c.jar.cause"
run cause "$T/noprecheck.json" pass pass
say cause "$(jq -r '[.runs[] | select(.role == "candidate") | .cause] | join(" ")' "$V")" "SETUP_PREFIX_RACE SETUP_PREFIX_RACE" "cause in verdict.json"
say cause "$(jq -r '[.runs[] | select(.role == "base") | (.cause // "null")] | join(" ")' "$V")" "null null" "no cause on VALID runs"
say cause "$(grep -c 'SETUP_PREFIX_RACE' "$T/o-cause/table.txt")" 2 "table shows the cause"
say cause "$(grep -c 'stub asked' "$V")" 0 "no free text in verdict.json"
printf 'not a code; rm -rf /' > "$T/cbad-c.jar.cause"
run cbad "$T/noprecheck.json" pass pass
say cbad "$(jq -r '[.runs[] | select(.role == "candidate") | (.cause // "null")] | join(" ")' "$V")" "null null" "malformed code dropped"

# 5. manifest validation
jq '.precheck = "../../run.sh"' "$M" > "$T/outside.json"
bash diffrun/run.sh "$T/outside.json" --base "$T/pass-b.jar" --candidate "$T/pass-c.jar" --out "$T/o-outside" > "$T/outside.log" 2>&1
say outside "$?" 2 "precheck outside scenarios/ rejected"
jq 'del(.precheck)' "$M" > "$T/orphan.json"
bash diffrun/run.sh "$T/orphan.json" --base "$T/pass-b.jar" --candidate "$T/pass-c.jar" --out "$T/o-orphan" > "$T/orphan.log" 2>&1
say orphan "$? $(grep -c 'needs precheck' "$T/orphan.log")" "2 1" "timeout without precheck rejected"

[[ $fail == 0 ]] && echo "precheck tests: all ok" || { echo "precheck tests: MISMATCH (see $T)"; exit 1; }
