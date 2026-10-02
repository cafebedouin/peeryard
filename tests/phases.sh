#!/usr/bin/env bash
# phases.sh: no-node tests of rig/lib/phases.sh (the data-scenario interpreter). The rig helpers are stubs that print
# scripted tokens (set per case in the environment: SC / SC_<a><b> for same_chain, SS for same_state, H_<n> heights,
# B_<n> balances, HH_<n> header heights); every action stub adds one to PHASES_TEST_ACTIONS. Run under set -uo
# pipefail with no -e, as rig.sh sources a hook. Then every hook under rig/examples/ that sources lib/phases.sh is
# linted (no shell in the data, no top-level statements) and checked with PHASES_CHECK=1. Run from the peeryard root:
#   T=$(mktemp -d) bash tests/phases.sh
# PHASES_LIB=<file> tests another copy of the interpreter (the falsifier run: a copy whose fold ignores a false pass
# must turn the `flipped` case into a MISMATCH).
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2
T="${T:?set T to a scratch dir, e.g. T=$(mktemp -d)}"
Tr="$(realpath -m -- "$T")"; Tmpr="$(realpath -m -- "${TMPDIR:-/tmp}")"
case "$Tr/" in /tmp/?*/|"$Tmpr"/?*/) ;; *) echo "refusing T='$T': not a scratch dir under /tmp or \$TMPDIR (use T=\$(mktemp -d))" >&2; exit 2 ;; esac
case "$PWD/" in "$Tr"/*) echo "refusing T='$T': it contains the current directory" >&2; exit 2 ;; esac
rm -rf "$T"; mkdir -p "$T"
EXPECT_HOOKS=3   # hooks under rig/examples/ that source lib/phases.sh; bumped with each one added
# the by-design WARNs of the check-only pass over the shipped hooks, as <hook>:<heredoc line>:<verb>; a new one is added
# here deliberately (an extra or a missing WARN is a MISMATCH)
EXPECT_WARNS=("bringup-phases:3:link_netem")
# shellcheck source=rig/lib/phases.sh
source "${PHASES_LIB:-rig/lib/phases.sh}"

# ---- stubs (the rig's helpers) ----
NODES=(A B C); HOOK="$PWD/tests/phases-test.sh"; PHASES_TEST_ACTIONS=0
act(){ PHASES_TEST_ACTIONS=$((PHASES_TEST_ACTIONS + 1)); }
tok(){ local v=$1; echo "${!v:-$2}"; }
same_chain(){ tok "SC_$1$2" "${SC:-SAME@10:aaaa}"; }
same_state(){ tok "SS_$1$2" "${SS:-SAME@10:root}"; }
full_height(){ tok "H_$1" 10; }
balance(){ tok "B_$1" 5000000000; }
rest(){ echo "{\"appVersion\":\"6.0.6\",\"headersHeight\":$(tok "HH_$1" 10)}"; }
check_topology(){ echo "  link A<->B: connected both ways"; return "${TOPO_RC:-0}"; }
settle_follow(){ act; SETTLE_STATE=${SETTLE_TOK:-SAME@13:root}; SETTLE_AFTER=$SETTLE_STATE; SETTLE_WAIT_S=1; SETTLE_TRICKLE=1; return "${SETTLE_RC:-0}"; }
flap(){ act; FLAP_LAST_HEIGHT=${FLAP_H:-42}; }
pay(){ act; if [[ ${PAY_OK:-1} == 1 ]]; then printf 'a%.0s' {1..64}; echo; else echo "rejected: not enough boxes"; fi; }
partition(){ act; }; heal(){ act; }; link_netem(){ act; }; start_mining(){ act; }; stop_mining(){ act; }; mark(){ act; }
my_obs(){ return "${OBS_RC:-0}"; }

# ---- harness ----
fail=0; cases=0; oks=0; LAST=""
report(){ cases=$((cases + 1)); if [[ $2 == ok ]]; then oks=$((oks + 1)); else fail=1; fi; printf '%-26s %-8s %s\n' "$1" "$2" "$3"; }
# chk <name> <verdict> <cause prefix, or - for none> <actions, or - to skip>; stdin: the scenario
chk(){ local name=$1 wv=$2 wc=$3 wa=$4 out got v c a r=ok
  out=$(PHASES_TEST_ACTIONS=0; phases 2>&1; echo "@@ ${rig_verdict:-}|${rig_cause:-}|$PHASES_TEST_ACTIONS")
  printf '%s\n' "$out" > "$T/$name.log"; LAST=$out
  got=${out##*@@ }; v=${got%%|*}; got=${got#*|}; a=${got##*|}; c=${got%|*}
  [[ $v == "$wv" ]] || r=MISMATCH
  if [[ $wc == - ]]; then [[ -z $c ]] || r=MISMATCH; else [[ $c == "$wc"* ]] || r=MISMATCH; fi
  [[ $wa == - || $a == "$wa" ]] || r=MISMATCH
  # every run, BAD_SCENARIO included, ends with exactly one well-formed RESULT_JSON line
  [[ $(grep -c '^RESULT_JSON ' <<<"$out") == 1 ]] && grep '^RESULT_JSON ' <<<"$out" | cut -d' ' -f2- | jq -e '.schema_version == 1' >/dev/null || r=MISMATCH
  report "$name" "$r" "want [$wv ${wc} actions=$wa]  got [$v $c actions=$a]"; }
json(){ grep '^RESULT_JSON ' <<<"$LAST" | cut -d' ' -f2- | jq -e "$1" >/dev/null 2>&1; }
not(){ ! "$@"; }
expect(){ local name=$1; shift; if "$@"; then report "$name" ok "$*"; else report "$name" MISMATCH "$*"; fi; }

# ---- verdict ----
chk pass2 PASS - 1 <<'EOF'
record h height A
partition A B
pass first: same_chain A B SAME >= @h
pass same_state A B SAME
EOF
expect pass2-json json '(.metrics.first == true) and (.metrics.L4 == true) and (.metrics.h == 10) and (.versions.A == "6.0.6") and (.scenario == "phases-test")'
SS=DIFF@10:A=r1:B=r2 chk flipped FAIL CLAUSE:L4 1 <<'EOF'
record h height A
partition A B
pass first: same_chain A B SAME >= @h
pass same_state A B SAME
EOF
expect flipped-json json '(.metrics.first == true) and (.metrics.L4 == false)'
B_A=0 chk balance-zero PASS - 0 <<'EOF'
record b balance A
pass value @b == 0
EOF
SC=DIFF@3:A=x:B=y chk floor-never INCONCLUSIVE SETUP_GATE 2 <<'EOF'
mark one
partition A B
floor same_chain A B SAME timeout 0 cause SETUP_GATE
heal A B
pass topology
EOF
SC=DIFF@3:A=x:B=y chk false-then-floor FAIL CLAUSE:early 0 <<'EOF'
pass early: same_chain A B SAME
floor same_chain A B SAME timeout 0
pass topology
EOF
H_B=4 chk wait-timeout FAIL WAIT_TIMEOUT:2 1 <<'EOF'
partition A B
wait height B >= 5 timeout 0
heal A B
EOF
chk wait-ok PASS - 0 <<'EOF'
wait height B >= 5 timeout 0
EOF

# ---- tokens: degraded ones are false for every clause ----
for t in NOHEIGHT NOID@5:A=x:B= NOROOT@5:A=r:B= "LAG@5,6 fork" "LAG@5,6 unknown"; do
  SC=$t chk "tok-diff[${t// /_}]" FAIL CLAUSE:L1 0 <<<"pass same_chain A B DIFF"
  SS=$t chk "tok-lag[${t// /_}]" FAIL CLAUSE:L1 0 <<<"pass same_state A B SAME_OR_LAG"
done
SS="LAG@5,6 same-chain" chk lag-same-chain-ok PASS - 0 <<<"pass same_state A B SAME_OR_LAG"
SS="LAG@5,6 same-chain" chk lag-under-same FAIL CLAUSE:L1 0 <<<"pass same_state A B SAME"

# ---- the checker: nothing runs on a bad line ----
chk typo-line5 INCONCLUSIVE BAD_SCENARIO:5: 0 <<'EOF'
partition A B
# a comment counts as a line

heal A B
mien A 3
pass topology
EOF
chk no-timeout INCONCLUSIVE BAD_SCENARIO:2: 0 <<'EOF'
partition A B
wait height A >= 3
EOF
chk undefined-ref INCONCLUSIVE BAD_SCENARIO:1: 0 <<'EOF'
pass height A >= @nope
record nope height A
EOF
chk label-vs-record INCONCLUSIVE BAD_SCENARIO:2: 0 <<'EOF'
pass h: topology
record h height A
EOF
chk label-vs-pay-sent INCONCLUSIVE BAD_SCENARIO:2: 0 <<'EOF'
pass pay_sent: topology
pay C B 1000
EOF
chk duplicate-label INCONCLUSIVE BAD_SCENARIO:2: 0 <<'EOF'
pass x: topology
pass x: synced A
EOF
chk unknown-node INCONCLUSIVE BAD_SCENARIO:1: 0 <<<"pass synced Z"
chk not-implemented INCONCLUSIVE BAD_SCENARIO:2: 0 <<'EOF'
partition A B
crash B
pass topology
EOF
chk reader-not-impl INCONCLUSIVE BAD_SCENARIO:1: 0 <<'EOF'
record hh headers_height A
pass topology
EOF
chk fn-undefined INCONCLUSIVE BAD_SCENARIO:1: 0 <<<"pass fn no_such_fn"
OBS_RC=0 chk fn-true PASS - 0 <<<"pass obs: fn my_obs"
OBS_RC=1 chk fn-false FAIL CLAUSE:obs 0 <<<"pass obs: fn my_obs"
chk settle-before-follow INCONCLUSIVE BAD_SCENARIO:1: 0 <<'EOF'
pass settle
settle_follow A B 5
EOF
chk no-claim INCONCLUSIVE BAD_SCENARIO:0: 0 <<<"partition A B"
chk when-subscript INCONCLUSIVE BAD_SCENARIO:1: 0 <<'EOF'
when A[0]=1 pass topology
pass topology
EOF

# ---- records, when, expressions ----
H_A=0 chk record-height-zero INCONCLUSIVE RECORD_EMPTY:h 1 <<'EOF'
partition A B
record h height A
pass topology
EOF
chk when-unset INCONCLUSIVE NO_CLAIM_EVALUATED 0 <<'EOF'
when PHASES_TEST_X=1 partition A B
when PHASES_TEST_X=1 pass topology
EOF
PHASES_TEST_X=1 chk when-set PASS - 1 <<'EOF'
when PHASES_TEST_X=1 partition A B
when PHASES_TEST_X=1 pass topology
EOF
chk expr-ok PASS - 0 <<'EOF'
record h height A
pass value @h+10 == 20
pass value (@h*3-6)/4 == 6
EOF
chk expr-upper INCONCLUSIVE BAD_SCENARIO:2: 0 <<'EOF'
record h height A
pass value @h+X == 20
EOF
chk expr-word INCONCLUSIVE BAD_SCENARIO:2: 0 <<'EOF'
record h height A
pass value @h+x == 20
EOF
chk expr-syntax INCONCLUSIVE BAD_SCENARIO:2: 0 <<'EOF'
record h height A
pass value @h+ == 20
EOF
B_B=0 chk expr-div-zero INCONCLUSIVE EXPR_ERROR:3 0 <<'EOF'
record a balance A
record b balance B
pass value @a/@b >= 1
EOF
expect expr-div-zero-lines grep -q '^\[phases\] === PHASES-TEST: INCONCLUSIVE' "$T/expr-div-zero.log"
FLAP_H=77 chk flap-last PASS - 1 <<'EOF'
flap A B 1 1 1
record x flap_last
pass value @x == 77
EOF
chk pay-count PASS - 3 <<'EOF'
pay C B 1000 3
pass value @pay_sent == 3
EOF
PAY_OK=0 chk pay-none INCONCLUSIVE NO_PAYMENTS 2 <<'EOF'
pay C B 1000 2
floor value @pay_sent >= 1 timeout 0 cause NO_PAYMENTS
pass topology
EOF
SETTLE_RC=1 SETTLE_TOK=DIFF@9:A=r:B=s chk settle-fails FAIL CLAUSE:settled 1 <<'EOF'
settle_follow A B 5 30
pass settled: settle
EOF
HH_A=9 chk not-synced FAIL CLAUSE:L1 0 <<<"pass synced A"
chk value-constants INCONCLUSIVE BAD_SCENARIO:1: 0 <<<"pass value 3 >= 1"
chk value-ref PASS - 0 <<'EOF'
record x height A
pass value @x >= 1
EOF

# ---- node-supplied text never executes: every numeric path goes through the operand regex ----
INJ="NODES[\$(touch $T/x)]"
# positive control: the same text compared without the regex runs its command (under set -u it then kills the shell)
bash -c 'set -u; NODES=(a); v=$1; [[ $v -ge 1 ]]' _ "NODES[\$(touch $T/y)]" 2>/dev/null
expect inj-control-runs test -e "$T/y"
H_A=$INJ chk inj-record-height INCONCLUSIVE RECORD_EMPTY:h 0 <<'EOF'
record h height A
pass topology
EOF
B_A=$INJ chk inj-record-balance INCONCLUSIVE RECORD_EMPTY:b 0 <<'EOF'
record b balance A
pass topology
EOF
B_A=$INJ chk inj-value-from-record INCONCLUSIVE RECORD_EMPTY:b 0 <<'EOF'
record b balance A
pass value @b+1 >= 1
EOF
H_A=$INJ chk inj-height-clause FAIL CLAUSE:L1 0 <<<"pass height A >= 1"
B_A=$INJ chk inj-balance-clause FAIL CLAUSE:L1 0 <<<"pass balance A >= 1"
H_A=$INJ chk inj-synced FAIL CLAUSE:L1 0 <<<"pass synced A"
SC="SAME@$INJ:id" chk inj-same-chain-height FAIL CLAUSE:L1 0 <<<"pass same_chain A B SAME >= 1"
expect inj-nothing-ran test ! -e "$T/x"
# an abort the interpreter does not catch (an arithmetic error inside a fn) leaves the named INCONCLUSIVE set first
expect abort-names-cause bash -c 'set -uo pipefail; source "$0"; check_topology(){ return 0; }; rest(){ :; }; NODES=(A); HOOK=x
rig_verdict=PASS; boom(){ local x; x=$(( 1/0 )); }; phases <<<"pass fn boom" >/dev/null 2>&1
[[ $rig_verdict == INCONCLUSIVE && $rig_cause == PHASES_ABORTED ]]' "${PHASES_LIB:-rig/lib/phases.sh}"

# ---- hooks that source lib/phases.sh: lint, then check ----
lint_hook(){ # <file>: data heredoc holds no shell beyond ${NAME:-default}; top level is functions, the source line, the heredoc
  local f=$1 body
  body=$(awk '/^phases <<EOF$/ {h = 1; next} h && /^EOF$/ {h = 0; next} h' "$f")
  if sed -E 's/\$\{[A-Za-z_][A-Za-z0-9_]*:-[^}$`]*\}//g' <<<"$body" | grep -qE '[$`]'; then echo "  $f: shell in the data (only \${NAME:-default} is allowed)"; return 1; fi
  awk 'h { if ($0 == "EOF") h = 0; next } fn { if ($0 ~ /^}/) fn = 0; next }
       /^[[:space:]]*(#|$)/ { next } /^phases <<EOF$/ { h = 1; next } /^source .*lib\/phases\.sh"$/ { next }
       /^[a-z_][a-z0-9_]*\(\) *\{/ { if ($0 !~ /\}[[:space:];]*$/) fn = 1; next }
       { print "  " FILENAME ":" NR ": top-level statement: " $0; bad = 1 } END { exit bad }' "$f"; }
check_hook(){ # <file>: PHASES_CHECK=1 with NODES from the sibling topology; prints the checker's line
  ( mapfile -t NODES < <(jq -r '.nodes[].name' "${1%.sh}.json"); HOOK=$(readlink -f "$1"); PHASES_CHECK=1
    # shellcheck disable=SC1090
    source "$1" ); }
mkdir -p "$T/rig/examples"; ln -s "$PWD/rig/lib" "$T/rig/lib"
printf '{"nodes":[{"name":"A"},{"name":"B"}]}\n' > "$T/rig/examples/typo.json"
cat > "$T/rig/examples/typo.sh" <<'HOOKEOF'
source "$(dirname "$(readlink -f "$HOOK")")/../lib/phases.sh"
phases <<EOF
partition A B
pass same_chain A B SAMEE
EOF
HOOKEOF
out=$(check_hook "$T/rig/examples/typo.sh" 2>&1); rc=$?
expect check-catches-typo-rc test "$rc" = 1
expect check-catches-typo-line grep -q 'BAD_SCENARIO line 2' <<<"$out"
printf '{"nodes":[{"name":"A"},{"name":"B"}]}\n' | tee "$T/rig/examples/tail.json" > "$T/rig/examples/notail.json"
printf 'source "$(dirname "$(readlink -f "$HOOK")")/../lib/phases.sh"\nphases <<EOF\npass topology\npartition A B\nwhen X=1 heal A B\nEOF\n' > "$T/rig/examples/tail.sh"
printf 'source "$(dirname "$(readlink -f "$HOOK")")/../lib/phases.sh"\nphases <<EOF\npartition A B\npass topology\nwhen X=1 heal A B\nEOF\n' > "$T/rig/examples/notail.sh"
out=$(check_hook "$T/rig/examples/tail.sh" 2>&1); rc=$?
expect warn-tail-action grep -q "WARN line 2: action 'partition'" <<<"$out"
expect warn-is-not-error test "$rc" = 0
expect no-warn-when-observed not grep -q WARN <<<"$(check_hook "$T/rig/examples/notail.sh" 2>&1)"
for bad in 'wait height A >= $H_X timeout 5' 'wait height A >= ${H_X} timeout 5' 'wait height A >= $(echo 5) timeout 5' 'wait height A >= `echo 5` timeout 5'; do
  printf 'phases <<EOF\npass topology\n%s\nEOF\n' "$bad" > "$T/lint.sh"
  expect "lint[${bad:17:12}]" not lint_hook "$T/lint.sh"
done
printf 'phases <<EOF\nwait height A >= ${H_X:-5} timeout 5\nEOF\n' > "$T/lint-ok.sh"
expect lint-knob-default lint_hook "$T/lint-ok.sh"
printf 'f(){ echo hi; }\ng(){\n  echo multi\n}\necho stray\nphases <<EOF\npass topology\nEOF\n' > "$T/shape.sh"
expect lint-top-level not lint_hook "$T/shape.sh"
n=0
while IFS= read -r f; do
  n=$((n + 1)); lint_hook "$f" && out=$(check_hook "$f" 2>&1); rc=$?
  expect "hook[$(basename "$f" .sh)]" test "$rc" = 0; printf '%s\n' "${out:-}" | sed 's/^/  /'
done < <(grep -lE '^source .*lib/phases\.sh' rig/examples/*.sh)
expect hooks-checked test "$n" = "$EXPECT_HOOKS"
warn_set(){ # <hook files...>: one <hook>:<line>:<verb> per WARN the check-only pass prints, sorted
  local f; for f in "$@"; do check_hook "$f" 2>&1 | sed -nE "s/^\[phases\] WARN line ([0-9]+): action '([a-z_]+)'.*/$(basename "$f" .sh):\1:\2/p"; done | sort; }
warns_pinned(){ [[ "$(warn_set "$@")" == "$(printf '%s\n' "${EXPECT_WARNS[@]}" | sort)" ]]; }
mapfile -t shipped < <(grep -lE '^source .*lib/phases\.sh' rig/examples/*.sh)
printf '%s\n' "$(warn_set "${shipped[@]}")" | sed 's/^/  warn: /'
expect warns-pinned warns_pinned "${shipped[@]}"
expect warns-pinned-catches-extra not warns_pinned "${shipped[@]}" "$T/rig/examples/tail.sh"

[[ $fail == 0 && $oks == "$cases" ]] && echo "phases tests: all $oks ok" || { echo "phases tests: MISMATCH ($oks of $cases ok; logs in $T)"; exit 1; }
