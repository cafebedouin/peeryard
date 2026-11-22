#!/usr/bin/env bash
# Evidence for ergoplatform/ergo pull request #2519 ("Release snapshot acquisition locks and preserve cleanup errors"),
# head 214b2dcc2b8ae414e741b883513510fe22c3af7c, merge base c1a69f65df2228ce26b7d1c2360b472ef79fc55c (master, v6.0.8).
# The change is in avldb's LDBVersionedStore.processSnapshot. Two parts:
#
# 1. Revert check of the pull request's own spec, scorex.db.LDBVersionedStoreSnapshotSpec (sbt "avldb/testOnly ...",
#    JDK 8, Scala 2.12), at the head and at the head with LDBVersionedStore.scala restored from the merge base.
# 2. A/B of two node jars built on the merge base with peeryard's diffrun/build.sh (the base, and the base plus the pull
#    request's production change). SnapshotAB.java runs once per jar and JDK, with the jar on the class path, so the
#    store opens its LevelDB through the node's own factory (native leveldbjni, as `java -jar` loads it). It drives
#    processSnapshot on a snapshot of a closed store, and through a proxy over the store's DB with an injected failure
#    in snapshot acquisition, in processing or in Snapshot.close (case list in SnapshotAB.java), plus a stable-view case.
#
# Claim: (1) the spec passes 15 of 15 at the head; restored, 9 fail and 6 pass, the failures being the nine tests listed
# in WANT_FAIL below. (2) On every JDK, every line of each jar is the one listed below for that jar: the base jar keeps the
# write lock after a failed acquisition (another thread cannot take it, a writer waits) and throws NullPointerException
# instead of returning the acquisition failure; the candidate returns the failure as a Failure and releases the lock;
# a close failure is returned as a Failure (base: thrown), a processing failure stays primary with the close failure
# suppressed (base: replaced by it), InterruptedException and ControlThrowable from processing propagate (base: a
# Failure); the other cases are the same on both jars. Both jars must load leveldbjni, and the lock probe must see a
# lock this thread holds.
# What counts against it: any other spec count or failing test, any line that differs from the listed one, a jar that
# does not load leveldbjni.
# The last line is "VERDICT: as claimed" (exit 0) or "VERDICT: NOT as claimed" (exit 1); exit 2 is a setup failure.
#
# Needs: git, sbt, sha256sum, JDKs 8/11/17/21 (JAVA_HOME_<v>_X64 on a GitHub-hosted runner, else JDK<v>_HOME), x86_64
# Linux (leveldbjni's bundled library), network access to github.com and to sbt's repositories.
# Touches: only WORKDIR (default: a new temporary directory, printed at the start and kept), apart from sbt's and
# coursier's own caches and sbt's socket directory (XDG_RUNTIME_DIR, default /tmp/sr-<uid>).
# Stop: Ctrl-C at any point; nothing runs in the background and nothing outside WORKDIR needs cleaning up.
# Quick mode: none. Two sbt test runs, two jar builds, eight harness runs of a few seconds each.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; py="$(cd "$here/../.." && pwd)"
WORKDIR="${WORKDIR:-$(mktemp -d)}"; mkdir -p "$WORKDIR"; WORKDIR="$(cd "$WORKDIR" && pwd)"; echo "WORKDIR=$WORKDIR"
for t in git sbt sha256sum; do command -v "$t" >/dev/null || { echo "missing tool: $t" >&2; exit 2; }; done
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/sr-$(id -u)}"; mkdir -p "$XDG_RUNTIME_DIR"

HEAD_SHA=214b2dcc2b8ae414e741b883513510fe22c3af7c
MB=c1a69f65df2228ce26b7d1c2360b472ef79fc55c
PROD=avldb/src/main/scala/scorex/db/LDBVersionedStore.scala
SPEC=scorex.db.LDBVersionedStoreSnapshotSpec
WANT_FAIL=(
  "snapshot acquisition failure releases the write lock"
  "snapshot acquisition failure is returned without processing or closing an absent snapshot"
  "snapshot close failure is returned as a Failure"
  "snapshot processing failure remains primary when closing also fails"
  "the same processing and close failure does not cause self-suppression"
  "processing control throwable propagates when ordinary close failure is false"
  "processing control throwable propagates when ordinary close failure is true"
  "processing interrupted exception propagates when ordinary close failure is false"
  "processing interrupted exception propagates when ordinary close failure is true"
)
I="logic=1 acq=1 closes=1 lockAtAcq=true heldAfter=false other=free"
declare -A WANT_BASE WANT_CAND
WANT_BASE=(
  [PC]="heldAfter=true other=blocked"
  [R1]="result=threw(NullPointerException) logic=0 heldAfter=true other=blocked suppressed=[]"
  [I1]="result=threw(NullPointerException) logic=0 acq=1 closes=0 lockAtAcq=true heldAfter=true other=blocked same=false suppressed=[] writer=blocked"
  [I1-after-release]="writer=done"
  [I2]="result=Failure(IllegalStateException) $I same=true suppressed=[]"
  [I3]="result=threw(IOException) $I same=true suppressed=[]"
  [I4]="result=threw(IOException) $I same=false suppressed=[]"
  [I5]="result=Failure(InterruptedException) $I same=true suppressed=[]"
  [I6]="result=Failure(NonLocalReturnControl) $I same=true suppressed=[]"
  [I7]="result=threw(InterruptedException) $I same=true suppressed=[]"
  [N1]="result=Success(1/1) logic=1 storeAfter=[2] heldAfter=false other=free"
)
WANT_CAND=(
  [PC]="heldAfter=true other=blocked"
  [R1]="result=Failure(DBException) logic=0 heldAfter=false other=free suppressed=[]"
  [I1]="result=Failure(DBException) logic=0 acq=1 closes=0 lockAtAcq=true heldAfter=false other=free same=true suppressed=[] writer=done"
  [I1-after-release]="writer=done"
  [I2]="result=Failure(IllegalStateException) $I same=true suppressed=[]"
  [I3]="result=Failure(IOException) $I same=true suppressed=[]"
  [I4]="result=Failure(IllegalStateException) $I same=true suppressed=[IOException]"
  [I5]="result=threw(InterruptedException) $I same=true suppressed=[]"
  [I6]="result=threw(NonLocalReturnControl) $I same=true suppressed=[]"
  [I7]="result=threw(InterruptedException) $I same=true suppressed=[]"
  [N1]="result=Success(1/1) logic=1 storeAfter=[2] heldAfter=false other=free"
)
CASES=(PC R1 I1 I1-after-release I2 I3 I4 I5 I6 I7 N1)

declare -A J
for v in 8 11 17 21; do h="$(eval echo "\${JAVA_HOME_${v}_X64:-\${JDK${v}_HOME:-}}")"
  [[ -n $h && -x $h/bin/java ]] || { echo "no JDK $v (set JDK${v}_HOME)" >&2; exit 2; }; J[$v]="$h"
  echo "JDK $v: $h ($("$h/bin/java" -version 2>&1 | head -1))"; done
echo "CPU: $(sed -n 's/^model name[[:space:]]*: //p' /proc/cpuinfo | head -1); $(uname -m)"

R="$WORKDIR/ergo"
[[ -d $R/.git ]] || git clone -q --filter=blob:none https://github.com/ergoplatform/ergo.git "$R" || exit 2
git -C "$R" fetch -q origin "refs/pull/2519/head:pr-2519" || exit 2
echo "PR #2519 head now: $(git -C "$R" rev-parse pr-2519) (tested: $HEAD_SHA)"
git -C "$R" cat-file -e "$HEAD_SHA^{commit}" 2>/dev/null || git -C "$R" fetch -q origin "$HEAD_SHA" || exit 2
[[ "$(git -C "$R" merge-base "$MB" "$HEAD_SHA")" == "$MB" ]] || { echo "$MB is not an ancestor of $HEAD_SHA" >&2; exit 2; }
git -C "$R" branch -f pr2519-tested "$HEAD_SHA" >/dev/null
bad=()

# 1. revert check of the spec
T="$WORKDIR/tree"; rm -rf "$T"; git -C "$R" worktree prune
git -C "$R" worktree add -q --detach "$T" "$HEAD_SHA" || exit 2
spec() {  # $1 = label: runs the spec in $T, prints the totals, the failed tests and the LevelDB backend it used
  ( cd "$T" && sbt -java-home "${J[8]}" -batch "avldb/testOnly $SPEC" ) > "$WORKDIR/spec-$1.log" 2>&1; local rc=$?
  sed -i 's/\x1b\[[0-9;]*m//g' "$WORKDIR/spec-$1.log"
  echo "== spec $1 (sbt exit $rc): $(grep -o 'Tests: succeeded [0-9]*, failed [0-9]*' "$WORKDIR/spec-$1.log" | tail -1)"
  grep -o 'Using the pure java LevelDB implementation\|Loaded org.fusesource.leveldbjni[^ ]*' "$WORKDIR/spec-$1.log" | sort | uniq -c | sed 's/^/   backend: /'
  grep -E '\*\*\* FAILED \*\*\*' "$WORKDIR/spec-$1.log" | sed -E 's/^\[info\] - //; s/ \*\*\* FAILED \*\*\*$//' | sort > "$WORKDIR/spec-$1.failed"
  sed 's/^/   failed: /' "$WORKDIR/spec-$1.failed"
}
spec head
git -C "$T" checkout -q "$MB" -- "$PROD" || exit 2
cmp -s <(git -C "$R" show "$MB:$PROD") "$T/$PROD" || { echo "the restored file is not the merge base's" >&2; exit 2; }
echo "restored $PROD from $MB: $(git -C "$T" diff --stat HEAD | tail -1)"
spec reverted
git -C "$R" worktree remove --force "$T"
grep -q 'Tests: succeeded 15, failed 0' "$WORKDIR/spec-head.log" || bad+=("spec at the head: not 15 passed, 0 failed")
grep -q 'Tests: succeeded 6, failed 9' "$WORKDIR/spec-reverted.log" || bad+=("spec restored: not 6 passed, 9 failed")
cmp -s "$WORKDIR/spec-reverted.failed" <(printf '%s\n' "${WANT_FAIL[@]}" | sort) || bad+=("spec restored: the failed tests are not the nine listed")

# 2. A/B of the two jars
export DIFFRUN_ERGO_CLONE="$R" DIFFRUN_CACHE="${DIFFRUN_CACHE:-$WORKDIR/builds}" JAVA8_HOME="${J[8]}" DIFFRUN_NO_LOCK=1
BASE_JAR="$(bash "$py/diffrun/build.sh" "$MB")" || { echo "base build failed" >&2; exit 2; }
CAND_JAR="$(bash "$py/diffrun/build.sh" "$MB" "$MB...pr2519-tested" -- src/main ergo-core/src/main ergo-wallet/src/main avldb/src/main)" \
  || { echo "candidate build failed" >&2; exit 2; }
sha256sum "$BASE_JAR" "$CAND_JAR" "$here/SnapshotAB.java"
mkdir -p "$WORKDIR/cls"; "${J[8]}/bin/javac" -cp "$BASE_JAR" -d "$WORKDIR/cls" "$here/SnapshotAB.java" || exit 2
for v in 8 11 17 21; do
  for arm in base candidate; do
    jar="$BASE_JAR"; [[ $arm == candidate ]] && jar="$CAND_JAR"
    d="$WORKDIR/ab-$arm-jdk$v"; rm -rf "$d"; mkdir -p "$d"
    ( cd "$d" && timeout 300 "${J[$v]}/bin/java" -cp "$jar:$WORKDIR/cls" SnapshotAB "$d/stores" ) > "$d/out.txt" 2>&1; rc=$?
    echo "== $arm jar, JDK $v (exit $rc)"
    grep -E '^(JAR|JAVA|FACTORY|CASE|END)' "$d/out.txt" | sed 's/^/   | /'
    # the node's own log lines, ids and numbers masked: what each jar logs about the cases
    grep -E ' (INFO|WARN|ERROR) ' "$d/out.txt" | grep -v 'Loaded org.fusesource' | sed -E 's/^[0-9:.]+ //; s/\[[^]]*\]//; s/[0-9]+/N/g' \
      | sort | uniq -c | sed 's/^/   log: /'
    grep -q '^FACTORY .*leveldbjni' "$d/out.txt" || bad+=("$arm JDK $v: leveldbjni not loaded")
    grep -q '^END' "$d/out.txt" || bad+=("$arm JDK $v: the harness did not finish (exit $rc)")
    for c in "${CASES[@]}"; do
      if [[ $arm == base ]]; then want="${WANT_BASE[$c]}"; else want="${WANT_CAND[$c]}"; fi
      got="$(sed -n "s/^CASE $c //p" "$d/out.txt")"
      [[ "$got" == "$want" ]] || bad+=("$arm JDK $v $c: got '$got', listed '$want'")
    done
  done
done
if [[ ${#bad[@]} == 0 ]]; then echo "VERDICT: as claimed"; exit 0; fi
printf '   %s\n' "${bad[@]}"; echo "VERDICT: NOT as claimed"; exit 1
