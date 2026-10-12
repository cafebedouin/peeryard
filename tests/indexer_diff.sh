#!/usr/bin/env bash
# indexer_diff.sh: no-node tests of rig/indexer-cmp.sh (the extra-indexer comparator) on the fixture snapshots in
# tests/fixtures/indexer-diff/: SAME, DIFF (a changed field, an absent address), each way of not being settled, the
# positive-control switch, and an unreadable input. Each case checks the exit code and a token of the verdict line.
# Run from the peeryard root:
#   T=$(mktemp -d) bash tests/indexer_diff.sh
# INDEXER_CMP=<file> tests another copy of the comparator (the falsifier: a copy that never reports DIFF must turn
# the DIFF cases into a MISMATCH).
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2
T="${T:?set T to a scratch dir, e.g. T=$(mktemp -d)}"
Tr="$(realpath -m -- "$T")"; Tmpr="$(realpath -m -- "${TMPDIR:-/tmp}")"
case "$Tr/" in /tmp/?*/|"$Tmpr"/?*/) ;; *) echo "refusing T='$T': not a scratch dir under /tmp or \$TMPDIR (use T=\$(mktemp -d))" >&2; exit 2 ;; esac
case "$PWD/" in "$Tr"/*) echo "refusing T='$T': it contains the current directory" >&2; exit 2 ;; esac
rm -rf "$T"; mkdir -p "$T"
CMP="${INDEXER_CMP:-rig/indexer-cmp.sh}"; F=tests/fixtures/indexer-diff; fail=0
# case <name> <want exit> <want token in line 1> <args...>
case_(){ local name="$1" want="$2" tok="$3"; shift 3; local out rc
  out="$(bash "$CMP" "$@" 2> "$T/stderr.txt")"; rc=$?
  if [[ "$rc" == "$want" ]] && grep -qF -- "$tok" <<< "$(head -1 <<< "$out")"; then printf '%-62s ok\n' "$name"
  else printf '%-62s MISMATCH (exit %s, want %s; want "%s" in: %s)\n' "$name" "$rc" "$want" "$tok" "$(head -1 <<< "$out")"; fail=1; fi
  echo "$out" > "$T/last.txt"; }   # the full output of the last case, for the follow-up checks

case_ "same tip, same answers -> SAME"                         0 "INDEXER-DIFF t SAME@40:aa00" --label t "$F/x.json" "$F/y-same.json"
case_ "meta (node name, version) is not compared"               0 "SAME@40" "$F/x.json" "$F/y-same.json"
case_ "a box's spent marker differs -> DIFF at that field"      1 'DIFF@.addresses.addrX.balance.nanoErgs x=4001000000 y=1000000 (2 of' "$F/x.json" "$F/y-diff.json"
case_ "... and the second field is listed"                      1 "INDEXER-DIFF compare DIFF@" "$F/x.json" "$F/y-diff.json"
grep -qF '  diff .boxes.1.spentTransactionId x=null y="t9"' "$T/last.txt" \
  && printf '%-62s ok\n' "... diff line names .boxes.1.spentTransactionId" || { printf '%-62s MISMATCH\n' "... diff line names .boxes.1.spentTransactionId"; fail=1; }
case_ "an address absent on one side -> DIFF with <absent>"     1 "y=<absent>" "$F/x.json" "$F/y-absent.json"
case_ "the absent side may be x as well"                        1 "x=<absent>" "$F/y-absent.json" "$F/x.json"
case_ "a block arrived during the read -> INCONCLUSIVE"         3 "INCONCLUSIVE not settled: y: moved during the read" "$F/x.json" "$F/y-moved.json"
case_ "indexer behind its full height -> INCONCLUSIVE"          3 "y: indexedHeight 38 != fullHeight 40" "$F/x.json" "$F/y-lagging.json"
case_ "a request answered 503 -> INCONCLUSIVE"                  3 'y: 1 request(s) not answered 200/404, first {"path":"/blockchain/balance","status":503}' "$F/x.json" "$F/y-error.json"
case_ "settled but on different tips -> INCONCLUSIVE"           3 "different best full blocks" "$F/x.json" "$F/y-later.json"
case_ "... the same pair under --positive-control -> DIFF"      1 "DIFF@.addresses.addrX.balance.nanoErgs x=4001000000 y=5001000000" --positive-control "$F/x.json" "$F/y-later.json"
case_ "--positive-control still requires each side settled"     3 "moved during the read" --positive-control "$F/x.json" "$F/y-moved.json"
case_ "--positive-control on identical answers stays SAME"      0 "SAME@40" --positive-control "$F/x.json" "$F/y-same.json"
echo 'not json' > "$T/bad.json"
case_ "an unreadable snapshot -> INCONCLUSIVE"                  3 "INCONCLUSIVE unreadable snapshot" "$F/x.json" "$T/bad.json"
case_ "--show 0 prints the verdict line only"                   1 "DIFF@" --show 0 "$F/x.json" "$F/y-diff.json"
[[ "$(wc -l < "$T/last.txt")" == 1 ]] && printf '%-62s ok\n' "... one line" || { printf '%-62s MISMATCH\n' "... one line"; fail=1; }

[[ $fail == 0 ]] && echo "indexer-diff comparator tests: all ok" || { echo "indexer-diff comparator tests: MISMATCH (see $T)"; exit 1; }
