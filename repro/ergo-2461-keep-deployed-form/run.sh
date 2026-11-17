#!/usr/bin/env bash
# Runs the NiPoPoW test suites of ergoplatform/ergo at three commits stacked on the head of pull request #2461:
#   PR #2461 head  97aa022687078726740785d3f1bce9756daf4f5f
#   T  tests       8b380e4cd  tests for the interlinks proof of a block which starts a voting epoch
#   X  exception   c1d1d1498  keep the interlinks-only proof for the first block of a voting epoch
#   K  key         55d93d833  keep the stored proof under the key deployed nodes use
# (branch nipopow/keep-deployed-proof-form of cafebedouin/ergo; the full ids are below and are checked).
#
# Claim: at T exactly three tests fail, the three new ones (two in ergo-core's PoPowHeaderSpec, one in the node
# module's PoPowAlgosWithDBSpec); at X and at K no test of the selection fails.
# What counts against it: any other failing test at T, fewer than three failures at T, or any failure at X or K.
# The last line is "VERDICT: as claimed" (exit 0) or "VERDICT: NOT as claimed" (exit 1).
#
# Needs: git, sbt, a JDK 8 (JAVA_HOME_8_X64 on a GitHub-hosted runner, else JAVA8_HOME, else JAVA_HOME), network
# access to github.com and to the repositories sbt resolves from. About 20 minutes on a hosted runner (one cold
# build, six test runs). Writes only under WORKDIR (default: a new temporary directory, printed at the start and
# kept), apart from what sbt and coursier keep in their own caches.
set -uo pipefail
WORKDIR="${WORKDIR:-$(mktemp -d)}"; mkdir -p "$WORKDIR"; WORKDIR="$(cd "$WORKDIR" && pwd)"; echo "WORKDIR=$WORKDIR"
for t in git sbt; do command -v "$t" >/dev/null || { echo "missing tool: $t" >&2; exit 2; }; done
JDK="${JAVA_HOME_8_X64:-${JAVA8_HOME:-${JAVA_HOME:-}}}"
[[ -n "$JDK" && -x "$JDK/bin/java" ]] || { echo "no JDK 8: set JAVA8_HOME" >&2; exit 2; }
"$JDK/bin/java" -version 2>&1 | head -1

PR_HEAD=97aa022687078726740785d3f1bce9756daf4f5f
T=8b380e4cd031b9ee8593217be2c53a1863b32919
X=c1d1d149854d2fe1ac3fc2aacdbd2a81f53acd46
K=55d93d83312edc48d66124b75332e82fc8045517
BRANCH=nipopow/keep-deployed-proof-form

R="$WORKDIR/ergo"
git clone -q --no-checkout https://github.com/ergoplatform/ergo.git "$R" || exit 2
git -C "$R" fetch -q origin "refs/pull/2461/head:pr2461" || exit 2
git -C "$R" fetch -q https://github.com/cafebedouin/ergo.git "refs/heads/$BRANCH:option" || exit 2
[[ "$(git -C "$R" rev-parse option)" == "$K" ]] || { echo "the branch is not at $K" >&2; exit 2; }
[[ "$(git -C "$R" rev-parse option~1)" == "$X" && "$(git -C "$R" rev-parse option~2)" == "$T" ]] || { echo "the branch's commits are not T, X, K" >&2; exit 2; }
[[ "$(git -C "$R" rev-parse option~3)" == "$PR_HEAD" ]] || { echo "the branch is not on the PR head $PR_HEAD" >&2; exit 2; }
echo "PR #2461 head now: $(git -C "$R" rev-parse pr2461) (the commits under test sit on $PR_HEAD)"

suites() {  # $1 label, $2 commit: prints the failed tests and the totals of both modules
  git -C "$R" checkout -q --detach "$2" || exit 2
  ( cd "$R" && sbt -java-home "$JDK" -batch "ergoCore/testOnly *PoPow* *Popow* *Nipopow*" ) > "$WORKDIR/$1-core.log" 2>&1; local c=$?
  ( cd "$R" && sbt -java-home "$JDK" -batch "testOnly *PoPow* *Popow* *Nipopow*" ) > "$WORKDIR/$1-node.log" 2>&1; local n=$?
  echo "== $1 $2: ergo-core exit=$c, node exit=$n"; echo "$c$n" > "$WORKDIR/$1-exit"
  grep -h -E '\*\*\* FAILED \*\*\*|Tests: succeeded' "$WORKDIR/$1-core.log" "$WORKDIR/$1-node.log" | sed 's/^/   /'
  grep -q 'Tests: succeeded' "$WORKDIR/$1-core.log" && grep -q 'Tests: succeeded' "$WORKDIR/$1-node.log" || {
    echo "   no test totals: the build did not get to the tests"; tail -20 "$WORKDIR/$1-core.log" "$WORKDIR/$1-node.log"; exit 2; }
}
failed() { cat "$WORKDIR/$1-core.log" "$WORKDIR/$1-node.log" | grep -c '\*\*\* FAILED \*\*\*'; }
exits() { cat "$WORKDIR/$1-exit"; }
has() { grep -q -F -- "$2" "$WORKDIR/$1-core.log" "$WORKDIR/$1-node.log"; }

suites T "$T"; suites X "$X"; suites K "$K"

bad=()
[[ "$(failed T)" == 3 ]] || bad+=("T: $(failed T) failed tests, 3 claimed")
has T "is accepted only for a header which starts a voting epoch *** FAILED ***" || bad+=("T: the acceptance test did not fail")
has T "as a mainnet node serves it is accepted with its interlinks-only proof *** FAILED ***" || bad+=("T: the mainnet header test did not fail")
has T "of a block which starts a voting epoch is the interlinks-only one *** FAILED ***" || bad+=("T: the prover test did not fail")
[[ "$(exits T)" == 11 ]] || bad+=("T: sbt exit codes $(exits T), 11 claimed (both modules have a failing test)")
[[ "$(failed X)" == 0 && "$(exits X)" == 00 ]] || bad+=("X: $(failed X) failed tests, sbt exit codes $(exits X)")
[[ "$(failed K)" == 0 && "$(exits K)" == 00 ]] || bad+=("K: $(failed K) failed tests, sbt exit codes $(exits K)")
if [[ ${#bad[@]} == 0 ]]; then echo "VERDICT: as claimed"; exit 0; fi
printf '   %s\n' "${bad[@]}"; echo "VERDICT: NOT as claimed"; exit 1
