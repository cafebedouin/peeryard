#!/usr/bin/env bash
# build-ref.sh: the build step of a hosted workflow for any ergo ref: a branch, a tag or a commit of
# ergoplatform/ergo (or of the clone's origin), built with diffrun/build.sh and copied out under a fixed name.
#
#   DIFFRUN_ERGO_CLONE=<clone> bash ci/build-ref.sh <ref> <out-dir> <name>
#
# <ref> is resolved against the clone's origin: a 40-hex commit (fetched when the clone lacks it), else a branch
# (refs/heads/<ref>, fetched first), else a tag (refs/tags/<ref>). A tag that shares a branch's name (a release
# branch once it is tagged) is reached by its commit. The build is diffrun/build.sh <commit>
# (no patch), with one retry: a cold sbt build can lose a dependency download to a transient repository error.
# Before the build, patches/sigma-snapshot.sh publishes the sigma-state snapshot the commit pins, if it pins one
# (a release version needs nothing). Writes <out-dir>/<name>.jar and <out-dir>/<name>.jar.json (the build sidecar:
# source_sha, expected_app_version, jar_sha256, stripped_jar_sha256) and prints the jar's path on the last line.
# Env as diffrun/build.sh (DIFFRUN_CACHE, JAVA8_HOME, SBT); DIFFRUN_NO_LOCK=1 on a CI runner.
set -euo pipefail
die(){ echo "build-ref: ERROR: $*" >&2; exit 2; }
[[ $# == 3 ]] || die "usage: $0 <ref> <out-dir> <name>"
REF="$1"; OUT="$2"; NAME="$3"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
C="${DIFFRUN_ERGO_CLONE:?set DIFFRUN_ERGO_CLONE to a clone of ergoplatform/ergo}"
[[ "$NAME" =~ ^[A-Za-z0-9._-]+$ ]] || die "name: [A-Za-z0-9._-]"
[[ "$REF" =~ ^[A-Za-z0-9._/-]{1,100}$ && "$REF" != *..* && "$REF" != -* ]] || die "ref: a branch, tag or commit name ([A-Za-z0-9._/-], no '..')"
if [[ "$REF" =~ ^[0-9a-f]{40}$ ]]; then
  git -C "$C" cat-file -e "$REF^{commit}" 2>/dev/null || git -C "$C" fetch -q origin "$REF"
  SHA="$REF"
elif git -C "$C" ls-remote --exit-code --heads origin "refs/heads/$REF" >/dev/null 2>&1; then
  git -C "$C" fetch -q origin "+refs/heads/$REF:refs/remotes/origin/$REF"; SHA="$(git -C "$C" rev-parse --verify "refs/remotes/origin/$REF^{commit}")"
elif git -C "$C" ls-remote --exit-code --tags origin "refs/tags/$REF" >/dev/null 2>&1; then
  git -C "$C" fetch -q origin "+refs/tags/$REF:refs/tags/$REF"; SHA="$(git -C "$C" rev-parse --verify "refs/tags/$REF^{commit}")"
else die "$REF is neither a 40-hex commit, a tag nor a branch of the clone's origin"; fi
echo "build-ref: $REF -> $SHA" >&2
DIFFRUN_ERGO_CLONE="$C" bash "$HERE/patches/sigma-snapshot.sh" "$SHA" >&2 || echo "build-ref: sigma-snapshot.sh failed; the build may not resolve sigma-state" >&2
jar=""
for attempt in 1 2; do
  jar="$(bash "$HERE/diffrun/build.sh" "$SHA" | tail -1)" && [[ -f "$jar" ]] && break
  echo "build-ref: build failed (attempt $attempt)" >&2; jar=""; sleep 20
done
[[ -n "$jar" ]] || die "diffrun/build.sh $SHA failed twice"
mkdir -p "$OUT"
cp "$jar" "$OUT/$NAME.jar"; cp "$jar.json" "$OUT/$NAME.jar.json"
[[ "$(jq -r .source_sha "$OUT/$NAME.jar.json")" == "$SHA" ]] || die "the sidecar's source_sha is not $SHA"
echo "build-ref: $OUT/$NAME.jar ($(jq -r '"appVersion \(.expected_app_version), sha256 \(.jar_sha256), stripped \(.stripped_jar_sha256 // "none")"' "$OUT/$NAME.jar.json"))" >&2
echo "$OUT/$NAME.jar"
