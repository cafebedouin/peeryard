#!/usr/bin/env bash
# crash_consistency.sh: no-node tests of rig/crash-verdict.sh (the crash-consistency outcome classifier) on the fixture
# observations in tests/fixtures/crash-consistency/: SAME (with and without kills, with an indexer line), each kind of
# DIFF (state root, best full block, a block off the reference's chain, a transient one in an early sample, the
# indexer's), LOGERR, STUCK, both REFUSED cases, and each INCONCLUSIVE reason. Each case checks the exit code and a
# token of the verdict line. Run from the peeryard root:
#   T=$(mktemp -d) bash tests/crash_consistency.sh
# CRASH_VERDICT=<file> tests another copy of the classifier (the falsifier: a copy that never reports DIFF must turn the
# DIFF cases into MISMATCH).
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2
T="${T:?set T to a scratch dir, e.g. T=$(mktemp -d)}"
Tr="$(realpath -m -- "$T")"; Tmpr="$(realpath -m -- "${TMPDIR:-/tmp}")"
case "$Tr/" in /tmp/?*/|"$Tmpr"/?*/) ;; *) echo "refusing T='$T': not a scratch dir under /tmp or \$TMPDIR (use T=\$(mktemp -d))" >&2; exit 2 ;; esac
case "$PWD/" in "$Tr"/*) echo "refusing T='$T': it contains the current directory" >&2; exit 2 ;; esac
rm -rf "$T"; mkdir -p "$T"
CV="${CRASH_VERDICT:-rig/crash-verdict.sh}"; F=tests/fixtures/crash-consistency; fail=0
# case_ <name> <want exit> <want token in the line> <fixture>
case_(){ local name="$1" want="$2" tok="$3" out rc
  out="$(bash "$CV" "$4" 2> "$T/stderr.txt")"; rc=$?
  if [[ "$rc" == "$want" ]] && grep -qF -- "$tok" <<< "$out"; then printf '%-62s ok\n' "$name"
  else printf '%-62s MISMATCH (exit %s, want %s; want "%s" in: %s)\n' "$name" "$rc" "$want" "$tok" "$out"; fail=1; fi; }

case_ "kills done, all agree at the end -> SAME"                  0 "CRASH-CONSISTENCY SAME@120:aaaa" "$F/same.json"
case_ "... the line carries the kill counts"                      0 "kills=3 in_window=3" "$F/same.json"
case_ "A/A (no kill planned) -> SAME"                             0 "SAME@120" "$F/aa.json"
case_ "state root differs at an equal height -> DIFF"             1 "DIFF@120 state root S=2222" "$F/diff-root.json"
case_ "best full block differs at an equal height -> DIFF"        1 "DIFF@120 best full block S=bbbb" "$F/diff-block.json"
case_ "subject below, on a block off R's chain -> DIFF"           1 "DIFF@118 off-chain" "$F/diff-offchain.json"
case_ "a DIFF in an early sample is kept though the last agrees"  1 "(sample 0)" "$F/diff-transient.json"
case_ "indexer comparator DIFF -> DIFF@indexer"                   1 "DIFF@indexer .boxes.7.spentTransactionId" "$F/indexer-diff.json"
case_ "indexer comparator SAME -> SAME with indexer=SAME"          0 "indexer=SAME" "$F/indexer-same.json"
case_ "indexer comparator INCONCLUSIVE -> INCONCLUSIVE"            3 "INCONCLUSIVE indexer: not settled" "$F/indexer-inconclusive.json"
case_ "agree, but an unrecoverable log line -> LOGERR"            1 "LOGERR@120 1 unrecoverable" "$F/logerr.json"
case_ "behind on the same chain at the end -> STUCK"              1 "STUCK@118/118 R=120 M=120" "$F/stuck.json"
case_ "never answered REST -> REFUSED"                            1 "REFUSED S does not answer REST at the end (never" "$F/refused-never.json"
case_ "answered, then not at the end -> REFUSED"                  1 "(it answered in an earlier sample)" "$F/refused-later.json"
case_ "fewer kills done than planned -> INCONCLUSIVE"             3 "INCONCLUSIVE staging: 2 of 3 kills done" "$F/inconclusive-kills.json"
case_ "no kill inside the apply window -> INCONCLUSIVE"           3 "0 kill(s) inside the apply window" "$F/inconclusive-window.json"
case_ "a harness failure -> INCONCLUSIVE"                         3 "INCONCLUSIVE harness: crash S" "$F/inconclusive-harness.json"
case_ "no sample -> INCONCLUSIVE"                                 3 "INCONCLUSIVE no sample taken" "$F/inconclusive-nosample.json"
case_ "the references disagree with each other -> INCONCLUSIVE"   3 "INCONCLUSIVE references disagree" "$F/ref-behind.json"
echo 'not json' > "$T/bad.json"
case_ "an unreadable observation -> exit 2"                       2 "INCONCLUSIVE unreadable observation" "$T/bad.json"

# pr-scenario.yml's scenario_env can reach the scenario's knobs: diffrun/scenario-env.sh sets only keys the manifest
# declares, so each knob must be declared (empty = the hook's own default)
cp diffrun/scenarios/crash-consistency.json "$T/m.json"
se(){ local want=$1 spec=$2 rc r; bash diffrun/scenario-env.sh "$T/m.json" "$spec" > "$T/se.out" 2>&1; rc=$?
  [[ $rc == "$want" ]] && r=ok || { r="MISMATCH ($(cat "$T/se.out"))"; fail=1; }
  printf 'scenario-env %-40s want exit %s got %s  %s\n' "'$spec'" "$want" "$rc" "$r"; }
se 0 'CC_ROLE=digest; CC_INDEXER=1; CC_KILL_ON=indexed; CC_CONTROL=aa'
se 1 'CC_NOT_A_KNOB=1'

[[ $fail == 0 ]] && echo "crash-consistency classifier tests: all ok" || { echo "crash-consistency classifier tests: MISMATCH (see $T)"; exit 1; }
