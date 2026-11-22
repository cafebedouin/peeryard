#!/usr/bin/env bash
# Test of a one-line change to the spec of ergoplatform/ergo pull request #2519, head
# 214b2dcc2b8ae414e741b883513510fe22c3af7c (merge base c1a69f65df2228ce26b7d1c2360b472ef79fc55c).
#
# The spec's test "snapshot acquisition failure is returned without processing or closing an absent snapshot" checks
# `Try(store.processSnapshot(...)).flatten shouldBe Failure(failure)`. Try.apply catches a thrown non-fatal exception,
# so the check also passes when processSnapshot throws the acquisition failure instead of returning it. The change
# (spec-returned.patch) calls processSnapshot directly, as the spec's close-failure tests already do.
# A mutant shows the difference: mutation-acquisition-outside-try.patch moves the snapshot acquisition (with its
# lock release) above the method's outer try, so an acquisition failure is thrown after the lock is released.
#
# Four runs of `sbt "avldb/testOnly scorex.db.LDBVersionedStoreSnapshotSpec"` (JDK 8):
#   A  head + change                         claim: 15 passed, 0 failed
#   B  head + mutant, spec unchanged         claim: 15 passed, 0 failed (the unchanged test accepts a thrown failure)
#   C  head + mutant + change                claim: 14 passed, 1 failed, the failed test being the one changed
#   D  merge-base LDBVersionedStore.scala + change   claim: 6 passed, 9 failed, the same nine tests that fail
#      with the unchanged spec on that file (the change keeps the test failing on the old code)
# What counts against it: any other count or failed test. Last line "VERDICT: as claimed" (exit 0) or
# "VERDICT: NOT as claimed" (exit 1); exit 2 is a setup failure.
#
# Needs: git, sbt, a JDK 8 (JAVA_HOME_8_X64 on a GitHub-hosted runner, else JAVA8_HOME), network access to github.com
# and sbt's repositories; ERGO_CLONE (optional) is an existing ergoplatform/ergo clone to fetch from.
# Touches only WORKDIR (default: a new temporary directory, printed and kept), apart from sbt's and coursier's caches and
# sbt's socket directory (XDG_RUNTIME_DIR, default /tmp/sr-<uid>). Stop: Ctrl-C. Quick mode: none.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKDIR="${WORKDIR:-$(mktemp -d)}"; mkdir -p "$WORKDIR"; WORKDIR="$(cd "$WORKDIR" && pwd)"; echo "WORKDIR=$WORKDIR"
for t in git sbt sha256sum; do command -v "$t" >/dev/null || { echo "missing tool: $t" >&2; exit 2; }; done
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/sr-$(id -u)}"; mkdir -p "$XDG_RUNTIME_DIR"
J8="${JAVA_HOME_8_X64:-${JAVA8_HOME:-}}"; [[ -n $J8 && -x $J8/bin/java ]] || { echo "no JDK 8 (set JAVA8_HOME)" >&2; exit 2; }
echo "JDK 8: $J8 ($("$J8/bin/java" -version 2>&1 | head -1))"
HEAD_SHA=214b2dcc2b8ae414e741b883513510fe22c3af7c
MB=c1a69f65df2228ce26b7d1c2360b472ef79fc55c
PROD=avldb/src/main/scala/scorex/db/LDBVersionedStore.scala
SPEC=scorex.db.LDBVersionedStoreSnapshotSpec
CHANGED="snapshot acquisition failure is returned without processing or closing an absent snapshot"
NINE=(
  "processing control throwable propagates when ordinary close failure is false"
  "processing control throwable propagates when ordinary close failure is true"
  "processing interrupted exception propagates when ordinary close failure is false"
  "processing interrupted exception propagates when ordinary close failure is true"
  "snapshot acquisition failure is returned without processing or closing an absent snapshot"
  "snapshot acquisition failure releases the write lock"
  "snapshot close failure is returned as a Failure"
  "snapshot processing failure remains primary when closing also fails"
  "the same processing and close failure does not cause self-suppression"
)
sha256sum "$here/spec-returned.patch" "$here/mutation-acquisition-outside-try.patch"

R="$WORKDIR/ergo"
if [[ ! -d $R/.git ]]; then
  if [[ -n ${ERGO_CLONE:-} ]]; then git clone -q --no-checkout "$ERGO_CLONE" "$R" || exit 2
  else git clone -q --no-checkout --filter=blob:none https://github.com/ergoplatform/ergo.git "$R" || exit 2; fi
fi
git -C "$R" cat-file -e "$HEAD_SHA^{commit}" 2>/dev/null || git -C "$R" fetch -q https://github.com/ergoplatform/ergo.git "refs/pull/2519/head" || exit 2
git -C "$R" cat-file -e "$HEAD_SHA^{commit}" || { echo "head $HEAD_SHA not found" >&2; exit 2; }
[[ "$(git -C "$R" merge-base "$MB" "$HEAD_SHA")" == "$MB" ]] || { echo "$MB is not an ancestor of $HEAD_SHA" >&2; exit 2; }
T="$WORKDIR/tree"; rm -rf "$T"; git -C "$R" worktree prune; git -C "$R" worktree add -q --detach "$T" "$HEAD_SHA" || exit 2

arm() {  # $1 label, rest: patches to apply on a clean head ("mb-prod" restores the production file from the merge base)
  local l="$1"; shift; git -C "$T" checkout -q -- . ; git -C "$T" clean -qfd
  for p in "$@"; do
    if [[ $p == mb-prod ]]; then git -C "$T" checkout -q "$MB" -- "$PROD" || exit 2
    else git -C "$T" apply "$here/$p" || { echo "$l: $p does not apply" >&2; exit 2; }; fi
  done
  ( cd "$T" && sbt -java-home "$J8" -batch "avldb/testOnly $SPEC" ) > "$WORKDIR/$l.log" 2>&1; local rc=$?
  sed -i 's/\x1b\[[0-9;]*m//g' "$WORKDIR/$l.log"
  grep -E '\*\*\* FAILED \*\*\*' "$WORKDIR/$l.log" | sed -E 's/^\[info\] - //; s/ \*\*\* FAILED \*\*\*$//' | sort > "$WORKDIR/$l.failed"
  echo "== $l ($*; sbt exit $rc): $(grep -o 'Tests: succeeded [0-9]*, failed [0-9]*' "$WORKDIR/$l.log" | tail -1)"
  echo "   diff vs head: $(git -C "$T" diff HEAD --stat | tail -1)"
  sed 's/^/   failed: /' "$WORKDIR/$l.failed"
}
arm A spec-returned.patch
arm B mutation-acquisition-outside-try.patch
arm C mutation-acquisition-outside-try.patch spec-returned.patch
arm D mb-prod spec-returned.patch
git -C "$R" worktree remove --force "$T"

bad=()
grep -q 'Tests: succeeded 15, failed 0' "$WORKDIR/A.log" || bad+=("A: not 15 passed, 0 failed")
grep -q 'Tests: succeeded 15, failed 0' "$WORKDIR/B.log" || bad+=("B: not 15 passed, 0 failed")
grep -q 'Tests: succeeded 14, failed 1' "$WORKDIR/C.log" || bad+=("C: not 14 passed, 1 failed")
cmp -s "$WORKDIR/C.failed" <(echo "$CHANGED") || bad+=("C: the failed test is not the changed one")
grep -q 'Tests: succeeded 6, failed 9' "$WORKDIR/D.log" || bad+=("D: not 6 passed, 9 failed")
cmp -s "$WORKDIR/D.failed" <(printf '%s\n' "${NINE[@]}" | sort) || bad+=("D: the failed tests are not the nine")
if [[ ${#bad[@]} == 0 ]]; then echo "VERDICT: as claimed"; exit 0; fi
printf '   %s\n' "${bad[@]}"; echo "VERDICT: NOT as claimed"; exit 1
