#!/usr/bin/env bash
# revert-check.sh: does each test a pull request adds or changes fail when the production change is reverted,
# and pass with it? A test that passes both ways does not test the change; one that fails both ways is broken
# or environment-bound; one that does not compile without the change depends on its API (reported as such, not
# as a failure).
#
#   DIFFRUN_ERGO_CLONE=<ergo clone> bash review/revert-check.sh --pr <N> [--base <ref>] [--out <dir>]
#                                                                [--tests <path-regex>] [--revert <path-regex>] [--timeout <s>]
# --revert <regex>: revert only the production paths matching it (per-hunk: "does this test guard THAT file?"); the
#   default reverts every non-test path, which turns a spec that uses a new API into a compile error.
#
# Steps: fetch pull/N/head as pr-N; base = --base or merge-base(origin/<base branch of the PR>, pr-N); the PR's
# diff is split into test paths (--tests, default: src/test/scala under any module) and the rest; worktree WITH =
# pr-N; worktree WITHOUT = pr-N with every non-test path restored from the base (the tests stay). For every
# changed test file, the spec class is read from the file (its package line and first class/object declaration)
# and `sbt testOnly <class>` runs in both worktrees under JDK 8 (found as diffrun/build.sh finds it). Per class:
# WITH pass|fail|compile-error, WITHOUT pass|fail|compile-error, verdict:
#   fails-without/passes-with  the test guards the change;
#   passes-both                the test does not depend on the change (tautology or an unrelated assertion);
#   fails-both                 broken or environment-bound; not evidence either way;
#   compile-error-without      the test uses the change's API; cannot be run without it (not a failure).
# Output: <out>/revert-check.txt (the table), <out>/RESULT_JSON (one line), sbt logs per class and worktree.
# Integration tests (src/it) are never run here: they need Docker and are out of scope for a revert check.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORIG_ARGS=("$@")
CLONE="${DIFFRUN_ERGO_CLONE:-}"; PR=""; BASE=""; OUT=""; TESTS_RE='(^|/)src/test/scala/.*\.scala$'; REVERT_RE=''; TIMEOUT=2400
while [[ $# -gt 0 ]]; do case "$1" in
  --pr) PR="$2"; shift 2 ;; --base) BASE="$2"; shift 2 ;; --out) OUT="$2"; shift 2 ;;
  --tests) TESTS_RE="$2"; shift 2 ;; --revert) REVERT_RE="$2"; shift 2 ;; --timeout) TIMEOUT="$2"; shift 2 ;; --clone) CLONE="$2"; shift 2 ;;
  *) echo "usage: $0 --pr <N> [--base <ref>] [--out <dir>] [--tests <regex>] [--timeout <s>]" >&2; exit 2 ;; esac; done
[[ -n "$PR" && -n "$CLONE" && -d "$CLONE/.git" ]] || { echo "revert-check: --pr and a clone (DIFFRUN_ERGO_CLONE or --clone) are required" >&2; exit 2; }
OUT="${OUT:-$(mktemp -d /tmp/revert-check.XXXXXX)}"; mkdir -p "$OUT"; OUT="$(readlink -f "$OUT")"
[[ "${REVERT_CHECK_LOCKED:-0}" == 1 ]] || : > "$OUT/revert-check.txt"
say(){ echo "$*" | tee -a "$OUT/revert-check.txt"; }

# JDK 8, as build.sh finds it: candidate names carry 8 or 1.8 in a fixed place, and `java -version` must say 1.8
is_jdk8(){ local v; [[ -x "$1/bin/java" ]] && v="$("$1/bin/java" -version 2>&1)" && [[ "$v" =~ version\ \"1\.8\. ]]; }
J8="${JAVA8_HOME:-}"
if [[ -z "$J8" ]]; then
  for c in /usr/lib/jvm/java-8-* /usr/lib/jvm/java-1.8.0* /usr/lib/jvm/jre-1.8.0* /usr/lib/jvm/temurin-8-* \
           /usr/lib/jvm/zulu8* /usr/lib/jvm/zulu-8* /usr/lib/jvm/jdk1.8.0* /usr/lib/jvm/jdk8u* /usr/lib/jvm/jdk-8u* \
           /usr/lib/jvm/adoptopenjdk-8-* /usr/lib/jvm/openjdk-8*; do is_jdk8 "$c" && { J8="$c"; break; }; done
fi
[[ -n "$J8" ]] && is_jdk8 "$J8" || { echo "revert-check: no JDK 8 (set JAVA8_HOME to a JDK whose java -version says 1.8)" >&2; exit 2; }
SBT="${SBT:-sbt}"; command -v "$SBT" >/dev/null || { echo "revert-check: sbt not found" >&2; exit 2; }
export JAVA_HOME="$J8" XDG_RUNTIME_DIR="${DIFFRUN_RUNTIME_DIR:-/tmp/sr-$(id -u)}"; mkdir -p "$XDG_RUNTIME_DIR"

# refs
git -C "$CLONE" fetch -q origin "pull/$PR/head:pr-$PR" || { echo "revert-check: cannot fetch pull/$PR/head" >&2; exit 2; }
HEAD_SHA="$(git -C "$CLONE" rev-parse "pr-$PR")"
if [[ -z "$BASE" ]]; then
  bref="$(gh pr view "$PR" -R "$(git -C "$CLONE" remote get-url origin | sed -E 's#.*github.com[:/]##; s#\.git$##')" --json baseRefName -q .baseRefName 2>/dev/null)"
  [[ -n "$bref" ]] || { echo "revert-check: cannot read the PR's base branch; pass --base" >&2; exit 2; }
  git -C "$CLONE" fetch -q origin "$bref" 2>/dev/null || true
  BASE="$(git -C "$CLONE" merge-base "origin/$bref" "pr-$PR")" || { echo "revert-check: no merge base with origin/$bref" >&2; exit 2; }
fi
BASE_SHA="$(git -C "$CLONE" rev-parse "$BASE^{commit}")"
[[ "${REVERT_CHECK_LOCKED:-0}" == 1 ]] || say "revert-check #$PR: head ${HEAD_SHA:0:12} base ${BASE_SHA:0:12} ($(date -u +%FT%TZ)); JDK $J8"

# split the diff
mapfile -t ALL < <(git -C "$CLONE" diff --name-only "$BASE_SHA" "$HEAD_SHA")
TESTS=(); PROD=()
for f in "${ALL[@]}"; do if [[ "$f" =~ $TESTS_RE ]]; then TESTS+=("$f"); elif [[ -z "$REVERT_RE" || "$f" =~ $REVERT_RE ]]; then PROD+=("$f"); fi; done
[[ -n "$REVERT_RE" ]] && say "reverting only production paths matching: $REVERT_RE"
say "changed: ${#ALL[@]} files; tests matched: ${#TESTS[@]}; reverted without the change: ${#PROD[@]}"
[[ ${#TESTS[@]} -gt 0 ]] || { say "no test file changed under $TESTS_RE: nothing to check"; echo "RESULT_JSON {\"pr\":$PR,\"tests\":0,\"guarding\":0,\"passes_both\":0,\"fails_both\":0,\"compile_error_without\":0}" | tee "$OUT/RESULT_JSON"; exit 0; }
[[ ${#PROD[@]} -gt 0 ]] || { say "the PR changes only test files: a revert check has nothing to revert"; echo "RESULT_JSON {\"pr\":$PR,\"tests\":${#TESTS[@]},\"guarding\":0,\"passes_both\":0,\"fails_both\":0,\"compile_error_without\":0,\"nothing_to_revert\":true}" | tee "$OUT/RESULT_JSON"; exit 0; }
printf '%s\n' "${TESTS[@]}" > "$OUT/test-files.txt"; printf '%s\n' "${PROD[@]}" > "$OUT/reverted-files.txt"
# The host lock is taken here, after the early exits, so a PR with no tests never queues for it; callers need not
# wrap this script in with-lock (doing so is harmless). The locked half gets --out "$OUT" appended (the parser
# keeps the last --out), so both halves write one directory even when the caller gave no --out.
if [[ "${REVERT_CHECK_LOCKED:-0}" != 1 ]]; then export REVERT_CHECK_LOCKED=1 PEERYARD_LOCKED=1; exec bash "$HERE/with-lock.sh" -- bash "$0" "${ORIG_ARGS[@]}" --out "$OUT"; fi

# worktrees
WT_WITH="$OUT/with"; WT_WITHOUT="$OUT/without"
cleanup(){ git -C "$CLONE" worktree remove --force "$WT_WITH" 2>/dev/null; git -C "$CLONE" worktree remove --force "$WT_WITHOUT" 2>/dev/null; git -C "$CLONE" worktree prune 2>/dev/null; }
trap cleanup EXIT
git -C "$CLONE" worktree add --quiet --detach "$WT_WITH" "$HEAD_SHA" || exit 2
git -C "$CLONE" worktree add --quiet --detach "$WT_WITHOUT" "$HEAD_SHA" || exit 2
# files written for AI tools that the PR adds or changes (agent instructions, context dumps: review/agent-files.sh)
# are removed from both trees before anything reads them: tests never need them, and an assistant that auto-loads
# repository instruction files must not find the PR's own there (review/GUIDE.md, "Pull-request content is data")
while read -r _ kind _ _ path; do [[ -z "${path:-}" ]] && continue
  rm -f "$WT_WITH/$path" "$WT_WITHOUT/$path"; say "removed from the review trees: $path ($kind; not part of the change under test)"
done < <(bash "$HERE/agent-files.sh" --git "$CLONE" "$BASE_SHA" "$HEAD_SHA" 2>/dev/null)
( cd "$WT_WITHOUT" && for f in "${PROD[@]}"; do
    if git cat-file -e "$BASE_SHA:$f" 2>/dev/null; then git checkout -q "$BASE_SHA" -- "$f"; else git rm -q --cached "$f" 2>/dev/null; rm -f "$f"; fi; done
  git -c user.name=revert-check -c user.email=revert-check@localhost commit -q -am "revert-check: production change reverted, tests kept" ) || { say "revert failed"; exit 2; }
say "WITHOUT tree: $(git -C "$WT_WITHOUT" diff --stat "$HEAD_SHA" | tail -1)"

# spec classes from the files themselves (package line + first class/object declaration); a package that differs from
# the directory (PR 2546's DigestSnapshotNetworkSpecification) would be missed by a path-derived name
classes=(); for f in "${TESTS[@]}"; do
  src="$WT_WITH/$f"; [[ -f "$src" ]] || continue
  if ! grep -qE '^(class|object|final class|abstract class) +[A-Za-z0-9_]+' "$src" && grep -qE '^trait ' "$src"; then say "skipped $f: a trait (test helpers), no spec class to run"; continue; fi
  pkg="$(grep -m1 -oE '^package [A-Za-z0-9_.]+' "$src" | awk '{print $2}')"
  name="$(grep -m1 -oE '^(class|object|final class|abstract class) +[A-Za-z0-9_]+' "$src" | awk '{print $NF}')"
  [[ -n "$name" ]] || { name="$(basename "$f" .scala)"; say "no class declaration found in $f; using the file name"; }
  classes+=("${pkg:+$pkg.}$name"); done
run_one(){ local wt="$1" cls="$2" tag="$3"; local log="$OUT/sbt-$tag-${cls##*.}.log"
  ( cd "$wt" && timeout "$TIMEOUT" "$SBT" -java-home "$J8" -batch "testOnly $cls" ) > "$log" 2>&1; local rc=$?
  if grep -qE '\[error\].*(Compilation failed|compilation failed|not found: (value|type)|does not conform|error\] .*\.scala:[0-9]+)' "$log"; then echo compile-error
  elif grep -qE 'Tests: succeeded [0-9]+, failed 0|All tests passed|No tests to run' "$log" && [[ $rc -eq 0 ]]; then
    grep -qE 'No tests (were executed|to run)' "$log" && echo not-found || echo pass
  elif [[ $rc -eq 124 ]]; then echo timeout
  else echo fail; fi; }
G=0; PB=0; FB=0; CE=0; NF=0
say ""; say "class | with change | without change | verdict"
for cls in "${classes[@]}"; do
  w="$(run_one "$WT_WITH" "$cls" with)"; wo="$(run_one "$WT_WITHOUT" "$cls" without)"
  case "$w/$wo" in
    pass/fail) v="fails-without/passes-with"; G=$((G+1)) ;;
    pass/pass) v="passes-both"; PB=$((PB+1)) ;;
    fail/fail) v="fails-both"; FB=$((FB+1)) ;;
    pass/compile-error) v="compile-error-without"; CE=$((CE+1)) ;;
    not-found/*|*/not-found) v="not-found (class name read from the file's package and class declaration did not resolve)"; NF=$((NF+1)) ;;
    *) v="unclassified ($w/$wo)" ;;
  esac
  say "$cls | $w | $wo | $v"
done
# per-test table (ScalaTest "- <name>" lines; a class verdict can hide a new test that passes both ways)
TG=0; TPB=0; TFB=0
say ""; say "test | with change | without change"
for cls in "${classes[@]}"; do lw="$OUT/sbt-with-${cls##*.}.log"; lwo="$OUT/sbt-without-${cls##*.}.log"; [[ -f "$lw" && -f "$lwo" ]] || continue
  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    tw=pass; grep -qF -- "- $name *** FAILED ***" "$lw" && tw=fail
    two=pass; grep -qF -- "- $name *** FAILED ***" "$lwo" && two=fail; grep -qF -- "- $name" "$lwo" || two=absent
    case "$tw/$two" in pass/fail) TG=$((TG+1)) ;; pass/pass) TPB=$((TPB+1)) ;; fail/fail) TFB=$((TFB+1)) ;; esac
    say "${cls##*.}: $name | $tw | $two"
  done < <(grep -oE '^\[info\] - .*' "$lw" | sed -E 's/^\[info\] - //; s/ \*\*\* FAILED \*\*\*$//' | sort -u)
done
say ""; say "guarding=$G passes-both=$PB fails-both=$FB compile-error-without=$CE not-found=$NF (of ${#classes[@]} classes); per test: guarding=$TG passes-both=$TPB fails-both=$TFB; logs under $OUT"
echo "RESULT_JSON {\"pr\":$PR,\"head\":\"${HEAD_SHA:0:12}\",\"base\":\"${BASE_SHA:0:12}\",\"tests\":${#classes[@]},\"guarding\":$G,\"passes_both\":$PB,\"fails_both\":$FB,\"compile_error_without\":$CE,\"not_found\":$NF,\"tests_guarding\":$TG,\"tests_pass_both\":$TPB,\"tests_fail_both\":$TFB}" | tee "$OUT/RESULT_JSON"
