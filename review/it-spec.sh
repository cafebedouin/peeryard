#!/usr/bin/env bash
# it-spec.sh: run one of ergo's own Docker integration specs (src/it) on a given ref, as upstream's CI does. ergo's
# integration suite is a dependency peeryard calls, not code it carries: it stages multi-node cases the rig does not
# (container stop/start under the suite's own harness, the flaky specs upstream tracks), and a maintainer can re-run
# the same command. Needs Docker, JDK 8 and sbt on this host (or run it on the fork's Actions instead:
# `gh workflow run fork-ci.yml -R <your ergo fork> -f ref=<ref> -f jobs=it` runs the whole suite there).
#
#   bash review/it-spec.sh <ergo clone> <ref> <SpecClass> [--out DIR]
#
# Builds the node image from a scratch worktree of <ref> (`sbt -Denv=test docker`, as regression/README.md says) and
# runs `it:testOnly <SpecClass>` with TMPDIR inside the worktree, as upstream's CI job does. Output: <DIR>/it.log,
# <DIR>/RESULT (PASS | FAIL | ERROR with the "Tests:" line), exit 0 on PASS, 1 on FAIL, 2 on a usage or build error.
# Wrap it in review/with-lock.sh: a node run and an it run on one host compete for CPU and the run's timing.
set -uo pipefail
[[ $# -ge 3 ]] || { sed -n '2,15p' "$0" >&2; exit 2; }
clone="$1"; ref="$2"; spec="$3"; shift 3; out="it-spec.$(date -u +%Y%m%dT%H%M%SZ)"
[[ "${1:-}" == --out ]] && { out="$2"; shift 2; }
for c in docker git sbt; do command -v "$c" >/dev/null || { echo "it-spec: missing $c" >&2; exit 2; }; done
git -C "$clone" rev-parse --verify --quiet "$ref^{commit}" >/dev/null || { echo "it-spec: $ref not in $clone" >&2; exit 2; }
docker info >/dev/null 2>&1 || { echo "it-spec: docker is not usable by this user" >&2; exit 2; }
mkdir -p "$out"; out="$(cd "$out" && pwd)"
is_jdk8(){ local v; [[ -x "$1/bin/java" ]] && v="$("$1/bin/java" -version 2>&1)" && [[ "$v" =~ version\ \"1\.8\. ]]; }
J8="${JAVA8_HOME:-}"
if [[ -z "$J8" ]]; then for c in /usr/lib/jvm/java-8-* /usr/lib/jvm/java-1.8.0* /usr/lib/jvm/temurin-8-* /usr/lib/jvm/zulu8* /usr/lib/jvm/jdk1.8.0* /usr/lib/jvm/openjdk-8*; do is_jdk8 "$c" && { J8="$c"; break; }; done; fi
[[ -n "$J8" ]] && is_jdk8 "$J8" || { echo "it-spec: no JDK 8 (set JAVA8_HOME)" >&2; exit 2; }
W="$(mktemp -d "${TMPDIR:-/tmp}/it-spec.XXXXXX")"; trap 'git -C "$clone" worktree remove --force "$W/wt" >/dev/null 2>&1; rm -rf "$W"' EXIT
git -C "$clone" worktree add -q --detach "$W/wt" "$ref" || { echo "it-spec: worktree failed" >&2; exit 2; }
sha="$(git -C "$W/wt" rev-parse HEAD)"; mkdir -p "$W/wt/tmp"
export JAVA_HOME="$J8" XDG_RUNTIME_DIR="${DIFFRUN_RUNTIME_DIR:-/tmp/sr-$(id -u)}"; mkdir -p "$XDG_RUNTIME_DIR"; chmod 700 "$XDG_RUNTIME_DIR"
{ echo "it-spec: $spec at $sha ($ref) from $clone, $(date -u +%FT%TZ)"; echo "command: TMPDIR=<worktree>/tmp sbt -Denv=test docker \"it:testOnly $spec\""; } | tee "$out/RESULT"
( cd "$W/wt" && TMPDIR="$W/wt/tmp" sbt -java-home "$J8" -batch -Denv=test docker "it:testOnly $spec" ) > "$out/it.log" 2>&1; rc=$?
line="$(grep -E '^\[info\] Tests: ' "$out/it.log" | tail -1)"
if [[ $rc -eq 0 && -n "$line" ]]; then v=PASS; elif [[ -n "$line" ]]; then v=FAIL; else v=ERROR; fi
grep -E '^\[info\] - .*(FAILED|\*\*\*)|^\[info\] Tests: ' "$out/it.log" | tail -8 >> "$out/RESULT"
echo "$v ${line:-(no Tests: line; see it.log, sbt exit $rc)}" | tee -a "$out/RESULT"
case $v in PASS) exit 0;; FAIL) exit 1;; *) exit 2;; esac
