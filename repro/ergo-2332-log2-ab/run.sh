#!/usr/bin/env bash
# A/B of NipopowAlgos.log2 for ergoplatform/ergo pull request #2332 ("make NipopowAlgos.log2 total, add level-boundary
# canary"), at head 067ced2a51c408b3e9d738a4e56b5d3f9826e9bb, merge base 5528ef569a41ebccbc8658212e6ee3c97d990b96 (v6.0.5).
#
# Builds two node jars on the merge base with peeryard's diffrun/build.sh: the base, and the base plus the pull
# request's production change. Then LevelAB.java loads both jars in one JVM, each in its own classloader, and computes
# the level (log2(T) - log2(h)).toInt the way maxLevelOf does, with each jar's own log2, over
#   - 983,280 rows next to a level boundary (six targets, k = 1..40, the 4097 doubles around T/2^k),
#   - 1,000,000 seeded random pairs (bit lengths 1..256),
#   - the pull request's three canary pairs.
# It does this on JDK 8, 11, 17, 21 and 25 (x86_64), each in default, -Xint and -Xcomp mode. Each run also reports
# replicas of the candidate's log2 with the shift threshold at 64, 128, 255, 256 and 977 (computed in the harness, not
# taken from a jar): their level differences from the base, and their bit differences from the candidate. The 977
# replica must equal the candidate on every row.
#
# Claim: no row differs between the jars, in level or in the bits of log2, on any runtime or mode; and the canary
# triple is class A (11,30,25) on JDK 8, class B (10,31,25) on JDK 11, 17 and 21, and one of A, B, C on JDK 25. The same
# three pairs' exact levels (integer arithmetic) and StrictMath.log levels are both 11,30,24 on every runtime and mode.
# What counts against it: any row that differs, any runtime whose triple is not as stated, an exact or StrictMath triple
# other than 11,30,24, or a 977 replica that differs from the candidate. The runner's CPU model is printed.
# The last line is "VERDICT: as claimed" (exit 0) or "VERDICT: NOT as claimed" (exit 1); exit 2 is a setup failure.
#
# Needs: git, sbt, curl, JDKs 8/11/17/21 (JAVA_HOME_<v>_X64 on a GitHub-hosted runner, else JDK<v>_HOME), network
# access to github.com and to sbt's repositories. JDK 25 is Temurin 25.0.5.1+2, fetched and checked by sha256 unless
# JDK25_HOME is set or the runner has one (JAVA_HOME_25_X64). Two cold sbt builds plus 15 harness runs (a few seconds
# each); about 9 minutes on a hosted runner. Writes only under WORKDIR (default: a new temporary directory, printed at the start and kept), apart from sbt's own caches.
# Stop: Ctrl-C at any point; nothing runs in the background and nothing outside WORKDIR needs cleaning up. Quick mode:
# none. After the builds, the 15 harness runs take a few minutes together.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; py="$(cd "$here/../.." && pwd)"
WORKDIR="${WORKDIR:-$(mktemp -d)}"; mkdir -p "$WORKDIR"; WORKDIR="$(cd "$WORKDIR" && pwd)"; echo "WORKDIR=$WORKDIR"
for t in git sbt curl sha256sum; do command -v "$t" >/dev/null || { echo "missing tool: $t" >&2; exit 2; }; done

HEAD_SHA=067ced2a51c408b3e9d738a4e56b5d3f9826e9bb
MB=5528ef569a41ebccbc8658212e6ee3c97d990b96
T25_URL="https://github.com/adoptium/temurin25-binaries/releases/download/jdk-25.0.5.1%2B2/OpenJDK25U-jdk_x64_linux_hotspot_25.0.5.1_2.tar.gz"
T25_SHA=760f91b22c3efc9bd1b64ff950598231be82928cc807e30691a0e7a2995a62c0

jdk() {  # $1 = 8|11|17|21|25: prints a JDK home or fails
  local v="$1" h; h="$(eval echo "\${JAVA_HOME_${v}_X64:-\${JDK${v}_HOME:-}}")"
  if [[ -z $h && $v == 25 ]]; then
    h="$WORKDIR/jdk-25"
    if [[ ! -x $h/bin/java ]]; then
      curl -sSL -o "$WORKDIR/t25.tgz" "$T25_URL" || return 1
      echo "$T25_SHA  $WORKDIR/t25.tgz" | sha256sum -c --quiet || return 1
      mkdir -p "$h" && tar -xzf "$WORKDIR/t25.tgz" -C "$h" --strip-components=1 || return 1
    fi
  fi
  [[ -n $h && -x $h/bin/java ]] || return 1; echo "$h"
}
for v in 8 11 17 21 25; do J[$v]="$(jdk $v)" || { echo "no JDK $v (set JDK${v}_HOME)" >&2; exit 2; }
  echo "JDK $v: ${J[$v]} ($("${J[$v]}/bin/java" -version 2>&1 | head -1))"; done

R="$WORKDIR/ergo"
[[ -d $R/.git ]] || git clone -q --filter=blob:none https://github.com/ergoplatform/ergo.git "$R" || exit 2
git -C "$R" fetch -q origin "refs/pull/2332/head:pr-2332" || exit 2
echo "PR #2332 head now: $(git -C "$R" rev-parse pr-2332) (tested: $HEAD_SHA)"
git -C "$R" cat-file -e "$HEAD_SHA^{commit}" 2>/dev/null || git -C "$R" fetch -q origin "$HEAD_SHA" || exit 2
[[ "$(git -C "$R" merge-base "$MB" "$HEAD_SHA")" == "$MB" ]] || { echo "$MB is not an ancestor of $HEAD_SHA" >&2; exit 2; }
git -C "$R" branch -f pr2332-tested "$HEAD_SHA" >/dev/null

export DIFFRUN_ERGO_CLONE="$R" DIFFRUN_CACHE="${DIFFRUN_CACHE:-$WORKDIR/builds}" JAVA8_HOME="${J[8]}" DIFFRUN_NO_LOCK=1
BASE_JAR="$(bash "$py/diffrun/build.sh" "$MB")" || { echo "base build failed" >&2; exit 2; }
CAND_JAR="$(bash "$py/diffrun/build.sh" "$MB" "$MB...pr2332-tested" -- src/main ergo-core/src/main ergo-wallet/src/main avldb/src/main)" \
  || { echo "candidate build failed" >&2; exit 2; }
sha256sum "$BASE_JAR" "$CAND_JAR"

echo "CPU: $(sed -n 's/^model name[[:space:]]*: //p' /proc/cpuinfo | head -1)"
mkdir -p "$WORKDIR/cls"; "${J[8]}/bin/javac" -d "$WORKDIR/cls" "$here/LevelAB.java" || exit 2
bad=()
for v in 8 11 17 21 25; do
  for mode in default -Xint -Xcomp; do
    flag=(); [[ $mode != default ]] && flag=("$mode")
    out="$WORKDIR/ab-jdk$v$mode.txt"
    "${J[$v]}/bin/java" ${flag[@]+"${flag[@]}"} -cp "$WORKDIR/cls" LevelAB "$BASE_JAR" "$CAND_JAR" > "$out" 2>&1; rc=$?
    sed 's/^/   | /' "$out"
    line="$(grep '^VERDICT' "$out" || echo "VERDICT MISSING (exit $rc)")"; echo "JDK $v $mode: $line"
    thl="$(grep '^threshold' "$out" || echo "threshold line missing")"; echo "   $thl"
    cxl="$(grep '^canary   exact' "$out" || echo "canary exact line missing")"; echo "   $cxl"
    [[ $cxl == "canary   exact=(11,30,24) strictmath=(11,30,24)" ]] || bad+=("JDK $v $mode: exact or StrictMath canary triple is not 11,30,24")
    [[ $thl == *"977 == candidate: ok"* ]] || bad+=("JDK $v $mode: the 977 replica differs from the candidate")
    [[ $line == "VERDICT SAME "* ]] || { bad+=("JDK $v $mode: rows differ or the run failed"); tail -5 "$out"; }
    cls="$(sed -n 's/.* class=\([A-Z]*\) .*/\1/p' <<<"$line")"
    case $v in 8) want=A;; 11|17|21) want=B;; 25) want="A B C";; esac
    [[ " $want " == *" $cls "* ]] || bad+=("JDK $v $mode: canary class ${cls:-none}, expected $want")
  done
done
if [[ ${#bad[@]} == 0 ]]; then echo "VERDICT: as claimed"; exit 0; fi
printf '   %s\n' "${bad[@]}"; echo "VERDICT: NOT as claimed"; exit 1
