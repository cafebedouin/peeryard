#!/usr/bin/env bash
# build.sh: build an ergo node jar from a git ref, optionally with one patch applied, and cache it with a sidecar.
#
#   DIFFRUN_ERGO_CLONE=<ergo clone> bash diffrun/build.sh [--dry-run] <base-ref> [<patch>] [-- <pathspec>...]
#
# <patch> is one of
#   a patch file            applied as it is (no pathspec allowed: the recorded bytes must be the applied bytes);
#   a commit                its first-parent diff;
#   a range  <a>..<b>       the diff from <a> to <b>;  <a>...<b>  the diff from merge-base(a, b) to <b>, which is
#                           what a pull request's diff is (fetch the head first, e.g.
#                           `git -C $DIFFRUN_ERGO_CLONE fetch origin pull/2511/head:pr-2511`, then `master...pr-2511`).
# `-- <pathspec>...` restricts a commit or range diff to those paths (git pathspec magic works, so `:!path`
# excludes). This is hunk isolation by file: build the base plus one part of a PR, then the base plus the rest, and
# run the same scenario on each jar. For a finer split, cut the patch file yourself and pass it.
# `--dry-run` prints the patch that would be applied and its sha256, then exits without building. A dry run
# needs no JDK and writes nothing to the cache (its scratch dir is under $TMPDIR and removed on exit).
#
# The build happens in a scratch `git worktree` of the clone (the clone's checkout is never touched). The patch is
# committed with a fixed author, committer, date and message, so the commit sha (and therefore sbt-dynver's
# appVersion) depends only on the base and the patch. The jar is built under JDK 8 in a temp dir inside the cache,
# then the entry is moved into place with one rename. An existing entry is never overwritten: a second build with
# the same inputs re-derives the patch commit, checks it against the entry and serves the cached jar.
#
# Prints the cached jar path on stdout. Beside it: <jar>.json (the sidecar) and <jar>.patch (the full diff of the
# production source dirs between the base and the built commit).
#
# Env: DIFFRUN_ERGO_CLONE (required), DIFFRUN_CACHE (default ~/.cache/diffrun/builds),
#      JAVA8_HOME (default: the first JDK 8 found under /usr/lib/jvm), SBT (default sbt).
# Empty arrays are expanded as ${a[@]+"${a[@]}"}: bash before 4.4 treats a plain "${a[@]}" of an empty array
# as unbound under `set -u`.
set -euo pipefail
die(){ echo "build: ERROR: $*" >&2; exit 2; }
USAGE="usage: $0 [--dry-run] <base-ref> [<patch-file> | <commit> | <a>..<b> | <a>...<b>] [-- <pathspec>...]"
DRY=0; POS=(); PATHS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY=1; shift ;;
    --) shift; PATHS=("$@"); break ;;
    -*) die "unknown option $1; $USAGE" ;;
    *) POS+=("$1"); shift ;;
  esac
done
[[ ${#POS[@]} -ge 1 && ${#POS[@]} -le 2 ]] || die "$USAGE"
[[ ${#PATHS[@]} == 0 || ${#POS[@]} == 2 ]] || die "a pathspec needs a commit or range to select from; $USAGE"
for p in ${PATHS[@]+"${PATHS[@]}"}; do [[ -n "$p" ]] || die "empty pathspec"; done
set -- "${POS[@]}"
CLONE="${DIFFRUN_ERGO_CLONE:?set DIFFRUN_ERGO_CLONE to a local clone of ergoplatform/ergo}"
CACHE="${DIFFRUN_CACHE:-$HOME/.cache/diffrun/builds}"
# is_jdk8 <home>: its java runs and reports version "1.8.x" (what every JDK 8 prints; 9+ print "9", "17.0.8", ...)
is_jdk8(){ local v; [[ -x "$1/bin/java" ]] && v="$("$1/bin/java" -version 2>&1)" && [[ "$v" =~ version\ \"1\.8\. ]]; }
J8="${JAVA8_HOME:-}"
if [[ -z "$J8" ]]; then   # find a JDK 8 under the usual roots; the distro paths differ (Debian, Fedora, Temurin, arm64)
  # the names carry the major version as 8 or 1.8 in a fixed place; no bare "*8*", which also matches jdk-17.0.8
  for c in /usr/lib/jvm/java-8-* /usr/lib/jvm/java-1.8.0* /usr/lib/jvm/jre-1.8.0* /usr/lib/jvm/temurin-8-* \
           /usr/lib/jvm/zulu8* /usr/lib/jvm/zulu-8* /usr/lib/jvm/jdk1.8.0* /usr/lib/jvm/jdk8u* /usr/lib/jvm/jdk-8u* \
           /usr/lib/jvm/adoptopenjdk-8-* /usr/lib/jvm/openjdk-8*; do
    is_jdk8 "$c" && { J8="$c"; break; }
  done
fi
SBT="${SBT:-sbt}"
PROD_DIRS=(src/main ergo-core/src/main ergo-wallet/src/main avldb/src/main)
FIXED_ID=(GIT_AUTHOR_NAME=diffrun GIT_AUTHOR_EMAIL=diffrun@invalid GIT_AUTHOR_DATE='2000-01-01T00:00:00+0000'
          GIT_COMMITTER_NAME=diffrun GIT_COMMITTER_EMAIL=diffrun@invalid GIT_COMMITTER_DATE='2000-01-01T00:00:00+0000')

git -C "$CLONE" rev-parse --git-dir >/dev/null 2>&1 || die "not a git clone: $CLONE"
BASE_REF="$1"; BASE_SHA="$(git -C "$CLONE" rev-parse --verify --quiet "$BASE_REF^{commit}")" || die "base ref not found: $BASE_REF"
if [[ $DRY == 1 ]]; then   # a dry run only derives the patch: no JDK needed, nothing written to the cache
  TMP="$(mktemp -d "${TMPDIR:-/tmp}/diffrun-dry.XXXXXX")"
else
  [[ -n "$J8" ]] || die "no JDK 8 found (set JAVA8_HOME; looked under /usr/lib/jvm; found: $(ls -d /usr/lib/jvm/* 2>/dev/null | tr '\n' ' '))"
  is_jdk8 "$J8" || die "JAVA8_HOME=$J8 is not a JDK 8: $("$J8/bin/java" -version 2>&1 | head -1)"
  mkdir -p "$CACHE"; CACHE="$(readlink -f "$CACHE")"
  TMP="$(mktemp -d "$CACHE/.tmp.XXXXXX")"
fi
WT="$TMP/wt"
cleanup(){ git -C "$CLONE" worktree remove --force "$WT" >/dev/null 2>&1 || true; rm -rf "$TMP"; }
trap cleanup EXIT

# ---- the patch: a file, a commit (its first-parent diff), a range (optionally restricted to paths), or none ----
PATCH_TYPE=none; PATCH_REF=""; PATCH_BYTES="$TMP/patch.diff"; : > "$PATCH_BYTES"
if [[ $# == 2 ]]; then
  if [[ -f "$2" ]]; then
    [[ ${#PATHS[@]} == 0 ]] || die "a pathspec cannot be applied to a patch file; cut the file yourself"
    PATCH_TYPE="file"; cp "$2" "$PATCH_BYTES"; PATCH_REF="$(sha256sum "$2" | cut -d' ' -f1)"
  elif [[ "$2" == *..* ]]; then
    # split at the first ".." or "..."; a ref name cannot contain ".." so the split is unambiguous
    if [[ "$2" == *...* ]]; then dots="..."; else dots=".."; fi
    a="${2%%"$dots"*}"; b="${2#*"$dots"}"
    [[ -n "$a" && -n "$b" && "$b" != .* ]] || die "bad range: $2 (want <a>..<b> or <a>...<b>)"
    A_SHA="$(git -C "$CLONE" rev-parse --verify --quiet "$a^{commit}")" || die "range start not found in the clone: $a"
    B_SHA="$(git -C "$CLONE" rev-parse --verify --quiet "$b^{commit}")" || die "range end not found in the clone: $b"
    PATCH_TYPE=range; PATCH_REF="$A_SHA$dots$B_SHA"
    git -C "$CLONE" diff --binary "$A_SHA$dots$B_SHA" -- ${PATHS[@]+"${PATHS[@]}"} > "$PATCH_BYTES"
  elif c="$(git -C "$CLONE" rev-parse --verify --quiet "$2^{commit}")"; then
    PATCH_TYPE=commit; PATCH_REF="$c"; git -C "$CLONE" diff --binary "$c^1" "$c" -- ${PATHS[@]+"${PATHS[@]}"} > "$PATCH_BYTES"
  else die "patch is neither a file, a commit nor a range in the clone: $2"; fi
  [[ -s "$PATCH_BYTES" ]] || die "patch is empty${PATHS[0]:+ (no change under the given pathspec)}"
fi
PATCH_SHA="none"; [[ $PATCH_TYPE != none ]] && PATCH_SHA="$(sha256sum "$PATCH_BYTES" | cut -d' ' -f1)"
KEY="${BASE_SHA:0:12}-${PATCH_SHA:0:12}"; ENTRY="$CACHE/$KEY"
if [[ $DRY == 1 ]]; then
  echo "build: dry run: base $BASE_SHA, patch $PATCH_TYPE ${PATCH_REF:-} sha256 $PATCH_SHA, cache key $KEY${PATHS[0]:+, paths: ${PATHS[*]}}" >&2
  echo "build: files: $(grep -c '^diff --git ' "$PATCH_BYTES" || true), changed lines: $(grep -cE '^[+-]' "$PATCH_BYTES" || true) (incl. headers)" >&2
  cat "$PATCH_BYTES"; exit 0
fi

# ---- the worktree and the deterministic patch commit ----
git -C "$CLONE" worktree add --quiet --detach "$WT" "$BASE_SHA" >&2
if [[ $PATCH_TYPE != none ]]; then
  git -C "$WT" apply --index "$PATCH_BYTES" || die "patch does not apply to $BASE_REF"
  env "${FIXED_ID[@]}" git -C "$WT" -c commit.gpgsign=false commit --quiet --no-verify -m "diffrun patch $PATCH_SHA" \
    || die "cannot commit the patch"
fi
HEAD_SHA="$(git -C "$WT" rev-parse HEAD)"
[[ -z "$(git -C "$WT" status --porcelain --untracked-files=no)" ]] || die "worktree is dirty after the patch commit"

# ---- cache hit: never overwritten; the re-derived commit must match the entry ----
if [[ -e "$ENTRY" ]]; then
  sc="$(ls "$ENTRY"/*.jar.json 2>/dev/null | head -1)"; [[ -n "$sc" ]] || die "cache entry has no sidecar: $ENTRY"
  jq -e --arg b "$BASE_SHA" --arg p "$PATCH_SHA" --arg h "$HEAD_SHA" \
     '.source_sha == $b and .patch.sha256 == $p and .build_commit == $h' "$sc" >/dev/null \
    || die "cache entry $ENTRY exists with different metadata (source, patch or commit); not overwriting"
  jar="${sc%.json}"
  [[ "$(sha256sum "$jar" | cut -d' ' -f1)" == "$(jq -r .jar_sha256 "$sc")" ]] || die "cached jar sha256 does not match its sidecar: $jar"
  echo "build: cache hit $KEY (commit $HEAD_SHA re-derived and matched)" >&2
  echo "$jar"; exit 0
fi

# ---- build under JDK 8 ----
echo "build: building $KEY (base $BASE_SHA, patch $PATCH_TYPE, commit $HEAD_SHA)" >&2
export JAVA_HOME="$J8" XDG_RUNTIME_DIR="${DIFFRUN_RUNTIME_DIR:-/tmp/sr-$(id -u)}"    # short, per-user: sbt's socket path must fit in 108 bytes
mkdir -p "$XDG_RUNTIME_DIR"; chmod 700 "$XDG_RUNTIME_DIR"
( cd "$WT" && "$SBT" -java-home "$J8" -batch assembly ) > "$TMP/build.log" 2>&1 \
  || { tail -30 "$TMP/build.log" >&2; die "sbt assembly failed"; }
mapfile -t jars < <(ls "$WT"/target/scala-2.12/ergo-*.jar 2>/dev/null)
[[ ${#jars[@]} == 1 ]] || die "expected exactly one assembled jar, found ${#jars[@]}"
JARNAME="$(basename "${jars[0]}")"; VER="${JARNAME#ergo-}"; VER="${VER%.jar}"   # assemblyJarName = ergo-${version}.jar

STAGE="$TMP/entry"; mkdir "$STAGE"
cp "${jars[0]}" "$STAGE/$JARNAME"
git -C "$WT" diff "$BASE_SHA" HEAD -- "${PROD_DIRS[@]}" > "$STAGE/$JARNAME.patch"
cp "$TMP/build.log" "$STAGE/build.log"
jq -n --arg src_ref "$BASE_REF" --arg src "$BASE_SHA" --arg ptype "$PATCH_TYPE" --arg pref "$PATCH_REF" --arg psha "$PATCH_SHA" \
      --arg head "$HEAD_SHA" --arg jsha "$(sha256sum "$STAGE/$JARNAME" | cut -d' ' -f1)" --arg ver "$VER" \
      --arg javav "$("$J8/bin/java" -version 2>&1 | head -1)" \
      --arg sbtjdk "$(grep -m3 -iE 'welcome to sbt|java.*1\.8\.0' "$TMP/build.log" | sed 's/\x1b\[[0-9;]*m//g' || true)" \
      --arg prodsha "$(sha256sum "$STAGE/$JARNAME.patch" | cut -d' ' -f1)" \
      --argjson dirs "$(printf '%s\n' "${PROD_DIRS[@]}" | jq -R . | jq -s .)" --arg at "$(date -u +%FT%TZ)" \
      --argjson paths "$( (for p in ${PATHS[@]+"${PATHS[@]}"}; do printf '%s\n' "$p"; done) | jq -R . | jq -s .)" \
      '{sidecar_schema_version: 1, kind: "build", source_ref: $src_ref, source_sha: $src,
        patch: {type: $ptype, ref: (if $pref == "" then null else $pref end), sha256: $psha, paths: $paths},
        build_commit: $head, jar_sha256: $jsha, expected_app_version: $ver,
        java_version: $javav, sbt_jdk_lines: ($sbtjdk | split("\n") | map(select(length > 0))),
        production_dirs: $dirs, production_patch_sha256: $prodsha, built_at: $at}' > "$STAGE/$JARNAME.json"

mv -T "$STAGE" "$ENTRY" || die "cannot move the build into $ENTRY (created concurrently?)"
echo "build: cached $ENTRY/$JARNAME (appVersion $VER)" >&2
echo "$ENTRY/$JARNAME"
