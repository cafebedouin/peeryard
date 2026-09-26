#!/usr/bin/env bash
# sigma-snapshot.sh: publish, to the local ivy cache, the sigma-state SNAPSHOT an ergo commit depends on.
#
# ergo's `weak-blocks` line pins `sigmaStateVersion` to a `-SNAPSHOT` built from a sigmastate-interpreter commit that is
# on no public repository, so `sbt assembly` on a fresh machine (a CI runner, a new clone) fails with
# "Error downloading org.scorexfoundation:sigma-state_2.12 <version>-SNAPSHOT". This script reads that version from
# the ergo commit's build.sbt; if `~/.ivy2/local` does not hold it, it clones sigmastate-interpreter at the commit the
# version names, checks `git describe --tags` reproduces the version (dynver stamps it from that; a shallow clone or a
# missing tag gives a different string and sbt keeps reporting the dependency unresolved), and runs
# `sbt ++<ergo's scala 2.12> sigma/publishLocal` under JDK 8 (the JVM root only; no JS modules). A release version (no
# `-SNAPSHOT`) needs nothing. Idempotent; cold about 3-4 minutes.
#
#   DIFFRUN_ERGO_CLONE=<ergo clone> bash patches/sigma-snapshot.sh [--dry-run] <ergo commit or ref>
# Env: JAVA8_HOME, SBT as diffrun/build.sh; SIGMA_CLONE (a clone to reuse; default a fresh one under $TMPDIR);
#      SIGMA_REPO (default https://github.com/ScorexFoundation/sigmastate-interpreter).
# Prints the published directory on success. --dry-run prints what it would do and exits 0 without JDK, clone or sbt.
set -euo pipefail
die(){ echo "sigma-snapshot: ERROR: $*" >&2; exit 1; }
DRY=0; [[ "${1:-}" == --dry-run ]] && { DRY=1; shift; }
REF="${1:?usage: $0 [--dry-run] <ergo commit or ref>}"
CLONE="${DIFFRUN_ERGO_CLONE:?set DIFFRUN_ERGO_CLONE to a local clone of ergoplatform/ergo}"
SIGMA_REPO="${SIGMA_REPO:-https://github.com/ScorexFoundation/sigmastate-interpreter}"
SHA="$(git -C "$CLONE" rev-parse --verify --quiet "$REF^{commit}")" || die "ref not found in the clone: $REF"
BUILD="$(git -C "$CLONE" show "$SHA:build.sbt")" || die "no build.sbt at $SHA"
VER="$(sed -nE 's/^val sigmaStateVersion = "([^"]+)".*/\1/p' <<<"$BUILD" | head -1)"
[[ -n "$VER" ]] || die "no 'val sigmaStateVersion = \"...\"' line in build.sbt at $SHA"
SCALA="$(sed -nE 's/^val scala212 = "([^"]+)".*/\1/p' <<<"$BUILD" | head -1)"; SCALA="${SCALA:-2.12.20}"
IVY="$HOME/.ivy2/local/org.scorexfoundation/sigma-state_2.12/$VER"
if [[ "$VER" != *-SNAPSHOT ]]; then echo "sigma-snapshot: sigma-state $VER is a release version: nothing to publish"; exit 0; fi
if [[ -f "$IVY/jars/sigma-state_2.12.jar" ]]; then echo "sigma-snapshot: present: $IVY"; exit 0; fi
# <tag>-<distance>-<hash>-SNAPSHOT, as sbt-dynver stamps a commit past a tag: the hash names the sigma commit to build
STEM="${VER%-SNAPSHOT}"; HASH="${STEM##*-}"; TAGDIST="${STEM%-*}"
[[ "$HASH" =~ ^[0-9a-f]{7,40}$ ]] || die "cannot read a commit hash from sigma-state version $VER"
echo "sigma-snapshot: ergo $SHA needs sigma-state $VER: sigmastate-interpreter commit $HASH, scala $SCALA"
if [[ $DRY == 1 ]]; then echo "sigma-snapshot: would clone $SIGMA_REPO, check out $HASH, run sbt ++$SCALA sigma/publishLocal under JDK 8, and publish to $IVY"; exit 0; fi
is_jdk8(){ local v; [[ -x "$1/bin/java" ]] && v="$("$1/bin/java" -version 2>&1)" && [[ "$v" =~ version\ \"1\.8\. ]]; }
J8="${JAVA8_HOME:-}"
if [[ -z "$J8" ]]; then
  for c in /usr/lib/jvm/java-8-* /usr/lib/jvm/java-1.8.0* /usr/lib/jvm/jre-1.8.0* /usr/lib/jvm/temurin-8-* \
           /usr/lib/jvm/zulu8* /usr/lib/jvm/zulu-8* /usr/lib/jvm/jdk1.8.0* /usr/lib/jvm/jdk8u* /usr/lib/jvm/jdk-8u* \
           /usr/lib/jvm/adoptopenjdk-8-* /usr/lib/jvm/openjdk-8*; do is_jdk8 "$c" && { J8="$c"; break; }; done
fi
[[ -n "$J8" ]] || die "no JDK 8 found (set JAVA8_HOME; looked under /usr/lib/jvm)"
is_jdk8 "$J8" || die "JAVA8_HOME=$J8 is not a JDK 8: $("$J8/bin/java" -version 2>&1 | head -1)"
SBT="${SBT:-sbt}"
SC="${SIGMA_CLONE:-}"
if [[ -z "$SC" ]]; then SC="$(mktemp -d "${TMPDIR:-/tmp}/sigma-snapshot.XXXXXX")/sigmastate-interpreter"
  echo "sigma-snapshot: cloning $SIGMA_REPO (full history: dynver needs the tags)"
  git clone -q "$SIGMA_REPO" "$SC"
elif ! git -C "$SC" cat-file -e "$HASH^{commit}" 2>/dev/null; then git -C "$SC" fetch -q --tags origin; fi
git -C "$SC" cat-file -e "$HASH^{commit}" 2>/dev/null || die "commit $HASH is not in the sigmastate-interpreter clone ($SC)"
git -C "$SC" checkout -q --detach "$HASH"
DESC="$(git -C "$SC" describe --tags 2>/dev/null || true)"   # v<tag>-<distance>-g<hash>
[[ "$DESC" == "v$TAGDIST-g$HASH"* ]] || die "git describe at $HASH gives '$DESC', not v$TAGDIST-g$HASH: dynver would not stamp $VER (shallow clone or missing tag?)"
export JAVA_HOME="$J8" XDG_RUNTIME_DIR="${DIFFRUN_RUNTIME_DIR:-/tmp/sr-$(id -u)}"; mkdir -p "$XDG_RUNTIME_DIR"; chmod 700 "$XDG_RUNTIME_DIR"
LOG="$(mktemp "${TMPDIR:-/tmp}/sigma-snapshot.XXXXXX.log")"
echo "sigma-snapshot: sbt ++$SCALA sigma/publishLocal in $SC (log: $LOG)"
( cd "$SC" && "$SBT" -java-home "$J8" -batch "++$SCALA" sigma/publishLocal ) > "$LOG" 2>&1 \
  || { tail -30 "$LOG" >&2; die "sbt publishLocal failed (log: $LOG)"; }
[[ -f "$IVY/jars/sigma-state_2.12.jar" ]] || die "publishLocal finished but $IVY/jars/sigma-state_2.12.jar is missing (log: $LOG)"
echo "sigma-snapshot: published $IVY"
