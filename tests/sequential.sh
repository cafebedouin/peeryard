#!/usr/bin/env bash
# sequential.sh: tests the sequential rule (max_n + stop_when) on the no-node replay stub
# diffrun/scenarios/test/seq-replay. Each case scripts the per-run switched pattern of base and candidate; the
# expected stop point and verdict are in the comment. No nodes, a few seconds. Run from the peeryard root:
#   T=$(mktemp -d) bash tests/sequential.sh
set -uo pipefail
T="${T:?set T to a scratch dir, e.g. T=$(mktemp -d)}"
# T is deleted and recreated below: refuse anything that is not a scratch dir under /tmp or $TMPDIR (where
# mktemp -d puts one), and anything that contains the current directory (T=. from the repo root).
Tr="$(realpath -m -- "$T")"; Tmpr="$(realpath -m -- "${TMPDIR:-/tmp}")"
case "$Tr/" in /tmp/?*/|"$Tmpr"/?*/) ;; *) echo "refusing T='$T': not a scratch dir under /tmp or \$TMPDIR (use T=\$(mktemp -d))" >&2; exit 2 ;; esac
case "$PWD/" in "$Tr"/*) echo "refusing T='$T': it contains the current directory" >&2; exit 2 ;; esac
rm -rf "$T"; mkdir -p "$T"
M=diffrun/scenarios/test/seq-replay.json
jq 'del(.max_n, .stop_when)' "$M" > "$T/fixed.json"
fail=0
run(){ local name=$1 man=$2 b=$3 c=$4 want=$5
  printf %s "$b" > "$T/$name-b.jar"; printf %s "$c" > "$T/$name-c.jar"
  bash diffrun/register.sh -f "$T/$name-b.jar" 1 2>/dev/null; bash diffrun/register.sh -f "$T/$name-c.jar" 1 2>/dev/null
  bash diffrun/run.sh "$man" --base "$T/$name-b.jar" --candidate "$T/$name-c.jar" --out "$T/o-$name" > "$T/$name.log" 2>&1
  got="$(jq -r '"\(.n_run) \(.sequential.stopped_by // "fixed") \(.verdict)"' "$T/o-$name/verdict.json")"
  [[ "$got" == "$want" ]] && r=ok || { r=MISMATCH; fail=1; }
  printf '%-8s base=%s cand=%s  want [%s]  got [%s]  %s\n' "$name" "$b" "$c" "$want" "$got" "$r"; }
run early   "$M"             FFTTTT TTTTTT "3 rule SUPPORTS"   # 2 base failures by pair 2; the minimum is 3
run late    "$M"             TTTTFF TTTTTT "6 rule SUPPORTS"   # the 2nd base failure comes in pair 6
run capped  "$M"             TTTTTF TTTTTT "6 cap NULL"        # only one base failure: cap, base predicate fails
run against "$M"             FFTTTT TTFTTT "3 rule AGAINST"    # candidate failed once
run fixed   "$T/fixed.json"  FFTTTT TTTTTT "3 fixed SUPPORTS"  # no sequential fields: exactly n pairs
# pair order is counterbalanced: offset 0 runs base first in pairs 1 and 3, the candidate first in pair 2; offset 1
# flips every pair (runs.jsonl lists the runs in the order they ran)
order(){ local off=$1 want=$2
  DIFFRUN_ORDER_OFFSET=$off bash diffrun/run.sh "$T/fixed.json" --base "$T/fixed-b.jar" --candidate "$T/fixed-c.jar" \
    --out "$T/o-order$off" > "$T/order$off.log" 2>&1
  got="$(jq -r '"\(.role[0:1])\(.index)@\(.slot)"' "$T/o-order$off/runs.jsonl" | tr '\n' ' ')"
  [[ "$got" == "$want" ]] && r=ok || { r=MISMATCH; fail=1; }
  printf '%-8s offset=%s  want [%s]  got [%s]  %s\n' order "$off" "$want" "$got" "$r"; }
order 0 "b1@1 c1@2 c2@1 b2@2 b3@1 c3@2 "
order 1 "c1@1 b1@2 b2@1 c2@2 c3@1 b3@2 "
DIFFRUN_ORDER_OFFSET=x bash diffrun/run.sh "$T/fixed.json" --base "$T/fixed-b.jar" --candidate "$T/fixed-c.jar" \
  --out "$T/o-orderx" > "$T/orderx.log" 2>&1; rc=$?
[[ $rc == 2 ]] && r=ok || { r=MISMATCH; fail=1; }; printf '%-8s offset=x  want [exit 2]  got [exit %s]  %s\n' order "$rc" "$r"
[[ $fail == 0 ]] && echo "sequential tests: all ok" || { echo "sequential tests: MISMATCH (see $T)"; exit 1; }
