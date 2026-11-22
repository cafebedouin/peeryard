#!/usr/bin/env bash
# Evidence for two ergoplatform/ergo pull requests that answer issue #2918 ("Modifiers message: no cap on the entry
# count"), both changing ergo-core's ModifiersSpec.parse:
#   #2942 "Cap ModifiersSpec.parse entry count at InvSpec.maxInvObjects (#2918)", head 43dc6b62aeafb5080c16a517f2965b217e777db7,
#         merge base 46d0beaa33562f099ff3579036238e78d314ed99 (v6.0.11);
#   #2958 "Reject a Modifiers message with more modifiers than a request can hold", head 7b018a31e3a77eac12ee3f5644498bc55c265ed3,
#         merge base 45f3d8433700e3455aa9821a993550a8b1ed86ad (v6.0.11, one commit earlier; the script checks that the
#         production sources of the two merge bases are identical, so one base jar serves both).
# Two parts:
# 1. Each pull request's own spec, org.ergoplatform.network.ModifiersSpecification (sbt "testOnly ...", JDK 8, Scala 2.12),
#    in one checkout: at each head; with ModifiersSpec.scala from the merge base (revert check); with the other pull
#    request's ModifiersSpec.scala (cross check); and with mutant-check-after-loop.patch, the merge-base file plus the
#    same cap checked only after the entries were read (does the spec see where the check sits?).
# 2. Three node jars built with peeryard's diffrun/build.sh: the base (46d0beaa3), #2942 on its merge base and #2958 on
#    its merge base, each from the pull request's production paths only. ModifiersAB.java runs once per jar and JDK
#    (8, 21) with the jar on the class path. It parses the same payloads with ModifiersSpec.parse (counts at, below and
#    above 400, repeated ids, the issue's case of as many empty entries as the byte budget admits, huge declared
#    counts, short buffers, large bodies at the byte budget), round-trips the reference vector of
#    ModifiersSpecification and two serializer-written messages, and passes some payloads to the node's handler entry
#    point Synchronizer.parseAndHandle with counting hooks (does the handler run, is the penalty hook called).
#
# Claim: (1) both specs pass 4 of 4 at their heads and on the other pull request's ModifiersSpec.scala; with the merge
# base's file each fails exactly its own new property; on the mutant #2942's spec fails its new property and #2958's
# spec passes 4 of 4. (2) On every JDK each jar prints exactly the lines listed below for it: the base parses up to
# 256071 empty entries and hands them to the handler, failing only at the byte budget; both pull requests reject any
# declared count above 400 after reading the count and nothing else, with their own message, and the handler then
# calls the penalty hook instead of the handler; counts 0-400, the byte budget, the reference vector and the malformed
# inputs come out the same on all three jars. The three jars' ModifiersSpec$ classes differ pairwise.
# What counts against it: any other spec count or failing test, any line that differs from the listed one.
# The last line is "VERDICT: as claimed" (exit 0) or "VERDICT: NOT as claimed" (exit 1); exit 2 is a setup failure.
#
# Needs: git, sbt, sha256sum, JDKs 8 and 21 (JAVA_HOME_<v>_X64 on a GitHub-hosted runner, else JDK<v>_HOME), network
# access to github.com and to sbt's repositories, about 2 GB of heap for the harness.
# Touches: only WORKDIR (default: a new temporary directory, printed at the start and kept), apart from sbt's and
# coursier's own caches and sbt's socket directory (XDG_RUNTIME_DIR, default /tmp/sr-<uid>).
# Stop: Ctrl-C at any point; nothing runs in the background and nothing outside WORKDIR needs cleaning up.
# Quick mode: none. Eight sbt test runs in one checkout, three jar builds, six harness runs of a few seconds each.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; py="$(cd "$here/../.." && pwd)"
WORKDIR="${WORKDIR:-$(mktemp -d)}"; mkdir -p "$WORKDIR"; WORKDIR="$(cd "$WORKDIR" && pwd)"; echo "WORKDIR=$WORKDIR"
for t in git sbt sha256sum; do command -v "$t" >/dev/null || { echo "missing tool: $t" >&2; exit 2; }; done
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/sr-$(id -u)}"; mkdir -p "$XDG_RUNTIME_DIR"

H42=43dc6b62aeafb5080c16a517f2965b217e777db7; MB42=46d0beaa33562f099ff3579036238e78d314ed99
H58=7b018a31e3a77eac12ee3f5644498bc55c265ed3; MB58=45f3d8433700e3455aa9821a993550a8b1ed86ad
PROD=ergo-core/src/main/scala/org/ergoplatform/network/message/ModifiersSpec.scala
SPEC=org.ergoplatform.network.ModifiersSpecification
P42="Modifiers parser accepts InvSpec.maxInvObjects entries and rejects counts above it"
P58="a Modifiers message with more modifiers than a request can hold is rejected"
PRODDIRS=(src/main ergo-core/src/main ergo-wallet/src/main avldb/src/main)

declare -A J
for v in 8 21; do h="$(eval echo "\${JAVA_HOME_${v}_X64:-\${JDK${v}_HOME:-}}")"
  [[ -n $h && -x $h/bin/java ]] || { echo "no JDK $v (set JDK${v}_HOME)" >&2; exit 2; }; J[$v]="$h"
  echo "JDK $v: $h ($("$h/bin/java" -version 2>&1 | head -1))"; done
echo "CPU: $(sed -n 's/^model name[[:space:]]*: //p' /proc/cpuinfo | head -1); $(uname -m)"

R="$WORKDIR/ergo"
[[ -d $R/.git ]] || git clone -q --filter=blob:none https://github.com/ergoplatform/ergo.git "$R" || exit 2
for n in 2942 2958; do git -C "$R" fetch -q origin "refs/pull/$n/head:pr-$n" || exit 2
  echo "PR #$n head now: $(git -C "$R" rev-parse "pr-$n")"; done
echo "tested: #2942 $H42, #2958 $H58"
for s in "$H42" "$H58" "$MB42" "$MB58"; do
  git -C "$R" cat-file -e "$s^{commit}" 2>/dev/null || git -C "$R" fetch -q origin "$s" || exit 2; done
[[ "$(git -C "$R" merge-base "$MB42" "$H42")" == "$MB42" ]] || { echo "$MB42 is not an ancestor of $H42" >&2; exit 2; }
[[ "$(git -C "$R" merge-base "$MB58" "$H58")" == "$MB58" ]] || { echo "$MB58 is not an ancestor of $H58" >&2; exit 2; }
[[ "$(git -C "$R" merge-base "$MB58" "$MB42")" == "$MB58" ]] || { echo "$MB58 is not an ancestor of $MB42" >&2; exit 2; }
git -C "$R" diff --quiet "$MB58" "$MB42" -- "${PRODDIRS[@]}" || { echo "production sources differ between the merge bases" >&2; exit 2; }
echo "production sources (${PRODDIRS[*]}) identical at $MB58 and $MB42; the whole diff between them: $(git -C "$R" diff --stat "$MB58" "$MB42" | sed 's/^ *//' | paste -sd ';' -)"
for n in 2942 2958; do h="$H42"; m="$MB42"; [[ $n == 2958 ]] && { h="$H58"; m="$MB58"; }
  echo "#$n production change: $(git -C "$R" diff --stat "$m" "$h" -- "${PRODDIRS[@]}" | tail -1)"; done
git -C "$R" branch -f pr2942-tested "$H42" >/dev/null; git -C "$R" branch -f pr2958-tested "$H58" >/dev/null
bad=()

# 1. the specs
T="$WORKDIR/tree"; rm -rf "$T"; git -C "$R" worktree prune
git -C "$R" worktree add -q --detach "$T" "$H42" || exit 2
spec() {  # $1 = label, $2 = tree commit, $3 = where ModifiersSpec.scala comes from (a commit, or "mutant")
  git -C "$T" checkout -q --force --detach "$2" || exit 2
  if [[ $3 == mutant ]]; then
    git -C "$T" show "$MB42:$PROD" > "$T/$PROD" && git -C "$T" apply "$here/mutant-check-after-loop.patch" || exit 2
  else git -C "$T" show "$3:$PROD" > "$T/$PROD" || exit 2; fi
  echo "== spec $1: tree $(git -C "$T" rev-parse --short=9 HEAD), $PROD sha256 $(sha256sum < "$T/$PROD" | cut -c1-12)"
  ( cd "$T" && timeout 3600 sbt -java-home "${J[8]}" -batch "testOnly $SPEC" ) > "$WORKDIR/spec-$1.log" 2>&1; local rc=$?
  sed -i 's/\x1b\[[0-9;]*m//g' "$WORKDIR/spec-$1.log"
  echo "   sbt exit $rc: $(grep -o 'Tests: succeeded [0-9]*, failed [0-9]*' "$WORKDIR/spec-$1.log" | tail -1)"
  grep -E '\*\*\* FAILED \*\*\*' "$WORKDIR/spec-$1.log" | sed -E 's/^\[info\] - //; s/ \*\*\* FAILED \*\*\*$//' | sort > "$WORKDIR/spec-$1.failed"
  sed 's/^/   failed: /' "$WORKDIR/spec-$1.failed"
  grep -A1 -E '\*\*\* FAILED \*\*\*' "$WORKDIR/spec-$1.log" | grep -v -E 'FAILED|^--' | sed 's/^\[info\] */   because: /'
}
want_spec() {  # $1 = label, $2 = "succeeded N, failed M", $3 = the failing test or ""
  grep -q "Tests: $2, canceled 0, ignored 0, pending 0\$" "$WORKDIR/spec-$1.log" || bad+=("spec $1: not '$2' (with 0 canceled, ignored, pending)")
  cmp -s "$WORKDIR/spec-$1.failed" <(if [[ -n $3 ]]; then echo "$3"; fi) || bad+=("spec $1: the failed tests are not '${3:-none}'")
}
spec 2942-head          "$H42" "$H42";   want_spec 2942-head          "succeeded 4, failed 0" ""
spec 2942-base-prod     "$H42" "$MB42";  want_spec 2942-base-prod     "succeeded 3, failed 1" "$P42"
spec 2942-with-2958prod "$H42" "$H58";   want_spec 2942-with-2958prod "succeeded 4, failed 0" ""
spec 2942-mutant        "$H42" mutant;   want_spec 2942-mutant        "succeeded 3, failed 1" "$P42"
spec 2958-head          "$H58" "$H58";   want_spec 2958-head          "succeeded 4, failed 0" ""
spec 2958-base-prod     "$H58" "$MB58";  want_spec 2958-base-prod     "succeeded 3, failed 1" "$P58"
spec 2958-with-2942prod "$H58" "$H42";   want_spec 2958-with-2942prod "succeeded 4, failed 0" ""
spec 2958-mutant        "$H58" mutant;   want_spec 2958-mutant        "succeeded 4, failed 0" ""
git -C "$R" worktree remove --force "$T"

# 2. the three jars
export DIFFRUN_ERGO_CLONE="$R" DIFFRUN_CACHE="${DIFFRUN_CACHE:-$WORKDIR/builds}" JAVA8_HOME="${J[8]}" DIFFRUN_NO_LOCK=1
declare -A JAR
JAR[base]="$(bash "$py/diffrun/build.sh" "$MB42")" || { echo "base build failed" >&2; exit 2; }
JAR[pr2942]="$(bash "$py/diffrun/build.sh" "$MB42" "$MB42...pr2942-tested" -- "${PRODDIRS[@]}")" || { echo "#2942 build failed" >&2; exit 2; }
JAR[pr2958]="$(bash "$py/diffrun/build.sh" "$MB58" "$MB58...pr2958-tested" -- "${PRODDIRS[@]}")" || { echo "#2958 build failed" >&2; exit 2; }
sha256sum "${JAR[base]}" "${JAR[pr2942]}" "${JAR[pr2958]}" "$here/ModifiersAB.java" "$here/mutant-check-after-loop.patch"

# the lines each jar must print; R42/R58 are the two pull requests' rejection messages
cap() { echo "Failure(IllegalArgumentException: requirement failed: $1 $2 in a message while limit is 400)"; }
U32="Failure(IllegalArgumentException: requirement failed: Not enough bytes in the buffer: 32)"
declare -A SAME
SAME=(
  [Z0]="result=Success(n=0) pos=2 bytes=2"
  [N1]="result=Success(n=1) pos=35 bytes=35"
  [N399]="result=Success(n=399) pos=13170 bytes=13170"
  [N400]="result=Success(n=400) pos=13203 bytes=13203"
  [D400-same-id]="result=Success(n=1) pos=13203 bytes=13203"
  [OVERINT-2147483648-no-entries]="result=Failure(ArithmeticException: Int overflow) pos=6 bytes=6"
  [TRUNC-400-declared-399-present]="result=$U32 pos=13170 bytes=13170"
  [LEN-1000-declared-10-present]="result=Failure(IllegalArgumentException: requirement failed: Not enough bytes in the buffer: 1000) pos=36 bytes=46"
  [BIG400-20453]="result=Success(n=400) pos=8195203 bytes=8195203"
  [BIG400-20454]="result=Failure(Exception: Too big message with modifiers, size: 8194304) pos=8175149 bytes=8195603"
  [RT-REF]="payload=261 bytes of the reference vector, parse=Success(n=1) type=101 rewritten=same-bytes"
  [RT-RT400]="written=400 entries by the jar's serializer, bytes=23003 parse=Success(n=400) same=true type=true"
  [SYNC-Z0]="result=Success handlerCalls=1 handlerEntries=0 penalizeMaliciousPeer=0"
  [SYNC-N400]="result=Success handlerCalls=1 handlerEntries=400 penalizeMaliciousPeer=0"
  [SYNC-HUGE-2147483647-no-entries]="result=Failure(IllegalArgumentException) handlerCalls=0 handlerEntries=- penalizeMaliciousPeer=1"
)
declare -A DIFF_BASE DIFF_PR
DIFF_BASE=(
  [N401]="result=Success(n=401) pos=13236 bytes=13236"
  [N401-proofs]="result=Success(n=401) pos=13236 bytes=13236"
  [D401-same-id]="result=Success(n=1) pos=13236 bytes=13236"
  [ISSUE-256071]="result=Success(n=256071) pos=8450347 bytes=8450347"
  [BUDGET-256072]="result=Failure(Exception: Too big message with modifiers, size: 8194304) pos=8450380 bytes=8450380"
  [HUGE-2147483647-no-entries]="result=$U32 pos=6 bytes=6"
  [RT-RT401]="written=401 entries by the jar's serializer, bytes=23036 parse=Success(n=401) same=true type=true"
  [SYNC-N401]="result=Success handlerCalls=1 handlerEntries=401 penalizeMaliciousPeer=0"
  [SYNC-ISSUE-256071]="result=Success handlerCalls=1 handlerEntries=256071 penalizeMaliciousPeer=0"
)
pr_lines() {  # $1 = the noun in the pull request's message
  DIFF_PR=(
    [N401]="result=$(cap 401 "$1") pos=3 bytes=13236"
    [N401-proofs]="result=$(cap 401 "$1") pos=3 bytes=13236"
    [D401-same-id]="result=$(cap 401 "$1") pos=3 bytes=13236"
    [ISSUE-256071]="result=$(cap 256071 "$1") pos=4 bytes=8450347"
    [BUDGET-256072]="result=$(cap 256072 "$1") pos=4 bytes=8450380"
    [HUGE-2147483647-no-entries]="result=$(cap 2147483647 "$1") pos=6 bytes=6"
    [RT-RT401]="written=401 entries by the jar's serializer, bytes=23036 parse=$(cap 401 "$1")"
    [SYNC-N401]="result=Failure(IllegalArgumentException) handlerCalls=0 handlerEntries=- penalizeMaliciousPeer=1"
    [SYNC-ISSUE-256071]="result=Failure(IllegalArgumentException) handlerCalls=0 handlerEntries=- penalizeMaliciousPeer=1"
  )
}
# what the node logs (ERROR/WARN/INFO lines, digits masked): one "Failed to deserialize" per SYNC failure
declare -A WANT_FAILLOG=([base]=1 [pr2942]=3 [pr2958]=3)

line_of() {  # $1 = out file, $2 = key: the CASE/RT/SYNC line's text after the name and the input hash removed
  local k="$2" kind=CASE name="$2"
  case $k in RT-*) kind=RT; name="${k#RT-}";; SYNC-*) kind=SYNC; name="${k#SYNC-}";; esac
  sed -n "s/^$kind $name //p" "$1" | sed -E 's/ in=[0-9a-f]{8}$//'
}
mkdir -p "$WORKDIR/cls"; "${J[8]}/bin/javac" -cp "${JAR[base]}" -d "$WORKDIR/cls" "$here/ModifiersAB.java" || exit 2
declare -A CLS INS
for v in 8 21; do
  for arm in base pr2942 pr2958; do
    d="$WORKDIR/ab-$arm-jdk$v"; rm -rf "$d"; mkdir -p "$d"
    ( cd "$d" && timeout 600 "${J[$v]}/bin/java" -Xmx2g -cp "${JAR[$arm]}:$WORKDIR/cls" ModifiersAB ) > "$d/out.txt" 2>&1; rc=$?
    echo "== $arm jar, JDK $v (exit $rc)"
    grep -E '^(JAR|JAVA|CLASS|CASE|RT|SYNC|END)' "$d/out.txt" | sed 's/^/   | /'
    grep -E ' (INFO|WARN|ERROR) ' "$d/out.txt" | sed -E 's/^[0-9:.]+ //; s/\[[^]]*\]//; s/[0-9]+/N/g' | sort | uniq -c | sed 's/^/   log: /'
    grep -q '^END' "$d/out.txt" || bad+=("$arm JDK $v: the harness did not finish (exit $rc)")
    grep -q '^CLASS .* InvSpec.maxInvObjects=400 maxMsgSizeWithReserve=8194304$' "$d/out.txt" || bad+=("$arm JDK $v: constants not 400 / 8194304")
    CLS[$arm-$v]="$(sed -n 's/^CLASS ModifiersSpec\$ sha256\[0:8\]=\([0-9a-f]*\).*/\1/p' "$d/out.txt")"
    INS[$arm-$v]="$(grep -E '^CASE ' "$d/out.txt" | sed -E 's/^CASE ([^ ]+) .* in=([0-9a-f]{8})$/\1=\2/' | tr '\n' ' ')"
    n="$(grep -c 'Failed to deserialize data from' "$d/out.txt")"
    [[ $n == "${WANT_FAILLOG[$arm]}" ]] || bad+=("$arm JDK $v: $n 'Failed to deserialize' log lines, listed ${WANT_FAILLOG[$arm]}")
    if [[ $arm == pr2942 ]]; then pr_lines elements; elif [[ $arm == pr2958 ]]; then pr_lines modifiers; fi
    for k in "${!SAME[@]}" "${!DIFF_BASE[@]}"; do
      if [[ -n ${SAME[$k]+x} ]]; then want="${SAME[$k]}"; elif [[ $arm == base ]]; then want="${DIFF_BASE[$k]}"; else want="${DIFF_PR[$k]}"; fi
      got="$(line_of "$d/out.txt" "$k")"
      [[ "$got" == "$want" ]] || bad+=("$arm JDK $v $k: got '$got', listed '$want'")
    done
  done
done
# the same inputs on every run; the three jars' ModifiersSpec$ classes differ pairwise and are stable across JDKs
for k in "${!INS[@]}"; do [[ "${INS[$k]}" == "${INS[base-8]}" ]] || bad+=("inputs differ: $k"); done
for arm in base pr2942 pr2958; do [[ -n ${CLS[$arm-8]} && "${CLS[$arm-8]}" == "${CLS[$arm-21]}" ]] || bad+=("$arm: ModifiersSpec\$ hash missing or not stable"); done
[[ "${CLS[base-8]}" != "${CLS[pr2942-8]}" && "${CLS[base-8]}" != "${CLS[pr2958-8]}" && "${CLS[pr2942-8]}" != "${CLS[pr2958-8]}" ]] \
  || bad+=("the three ModifiersSpec\$ classes are not pairwise different")
echo "inputs (case=sha256[0:8]): ${INS[base-8]}"
if [[ ${#bad[@]} == 0 ]]; then echo "VERDICT: as claimed"; exit 0; fi
printf '   %s\n' "${bad[@]}"; echo "VERDICT: NOT as claimed"; exit 1
