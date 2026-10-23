#!/usr/bin/env bash
# docker/run.sh [options] [-- command...]: run peeryard in its container with every flag the rig needs, and say what
# is being done. Without a command, a shell at /peeryard (the clone, mounted). Builds the image the first time.
#
#   bash docker/run.sh                                      # a shell in the container
#   bash docker/run.sh -- bash rig/preflight.sh             # one command, then exit
#   PEERYARD_JAR=~/ergo-6.0.8.jar bash docker/run.sh -- bash rig/rig.sh rig/examples/bringup.json rig/examples/bringup.sh
#
# What is mounted, and why:
#   this clone              -> /peeryard      the commands of the README run unchanged from here
#   $PEERYARD_DOCKER_HOME   -> /home/peer     the container's home: jar, sbt and coursier caches and ~/.peeryard
#                                              (devnets) survive container restarts; default ~/.peeryard/docker-home
#   dirname $PEERYARD_JAR   -> /jars (ro)     when PEERYARD_JAR is set; inside, PEERYARD_JAR points at /jars/<file>
#   $DIFFRUN_ERGO_CLONE     -> /ergo          when set (the ergo clone diffrun/build.sh and review/ work from);
#                                              inside, DIFFRUN_ERGO_CLONE=/ergo
# Other PEERYARD_* and DIFFRUN_* variables pass through unchanged (paths in them must be container paths), and GH_TOKEN
# when set (the image has gh but no credentials; review/pick.sh and reading PR threads need a token).
#
# The flags (docker/Dockerfile explains each): --init; --security-opt seccomp=unconfined, apparmor=unconfined,
# systempaths=unconfined. No --privileged, no root inside. On a Linux host the container runs as your uid, so what it
# writes into the mounts is yours.
#
# Options: --build (rebuild the image), --image <name> (default peeryard), --dry-run (print the command only),
# -h/--help. Runs with bash 3.2 (macOS) or later.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/.." && pwd)"
IMAGE="${PEERYARD_DOCKER_IMAGE:-peeryard}"; BUILD=0; DRY=0
say(){ echo "[docker/run.sh] $*" >&2; }
while [ $# -gt 0 ]; do
  case "$1" in
    --build) BUILD=1; shift ;;
    --image) IMAGE="$2"; shift 2 ;;
    --dry-run|-n) DRY=1; shift ;;
    -h|--help) sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    --) shift; break ;;
    -*) say "unknown option $1 (see --help)"; exit 2 ;;
    *) break ;;
  esac
done
command -v docker >/dev/null || { say "docker not found: install Docker (Docker Desktop on macOS and Windows)"; exit 2; }
if [ "$DRY" = 0 ] && ! docker info >/dev/null 2>&1; then say "the Docker daemon is not reachable (is Docker Desktop running?)"; exit 2; fi

if [ "$DRY" = 0 ] && { [ "$BUILD" = 1 ] || ! docker image inspect "$IMAGE" >/dev/null 2>&1; }; then
  say "building the image $IMAGE from docker/Dockerfile (Ubuntu 24.04, Java 21, JDK 8, sbt; a few minutes, once)"
  docker build -t "$IMAGE" "$HERE"
fi

DHOME="${PEERYARD_DOCKER_HOME:-$HOME/.peeryard/docker-home}"
[ "$DRY" = 1 ] || mkdir -p "$DHOME"

# The command line is built as a string of quoted words, so it runs on bash 3.2 (no arrays needed) and prints as the
# line a person could paste.
q(){ printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
CMD="docker run --rm --init"
[ -t 0 ] && [ -t 1 ] && CMD="$CMD -it"
CMD="$CMD --security-opt seccomp=unconfined --security-opt apparmor=unconfined --security-opt systempaths=unconfined"
CMD="$CMD --hostname peeryard"
case "$(uname -s)" in Linux) CMD="$CMD --user $(id -u):$(id -g)" ;; esac
CMD="$CMD -v $(q "$ROOT"):/peeryard -v $(q "$DHOME"):/home/peer"
say "clone $ROOT -> /peeryard; home (caches, devnets) $DHOME -> /home/peer"
if [ -n "${PEERYARD_JAR:-}" ]; then
  [ -f "$PEERYARD_JAR" ] || { say "PEERYARD_JAR=$PEERYARD_JAR is not a file"; exit 2; }
  JDIR="$(cd "$(dirname "$PEERYARD_JAR")" && pwd)"; JBASE="$(basename "$PEERYARD_JAR")"
  CMD="$CMD -v $(q "$JDIR"):/jars:ro -e PEERYARD_JAR=/jars/$(q "$JBASE" | sed "s/^'//; s/'\$//")"
  say "node jar $PEERYARD_JAR -> /jars/$JBASE (read-only)"
fi
if [ -n "${DIFFRUN_ERGO_CLONE:-}" ]; then
  [ -d "$DIFFRUN_ERGO_CLONE/.git" ] || { say "DIFFRUN_ERGO_CLONE=$DIFFRUN_ERGO_CLONE is not a git clone"; exit 2; }
  CMD="$CMD -v $(q "$(cd "$DIFFRUN_ERGO_CLONE" && pwd)"):/ergo -e DIFFRUN_ERGO_CLONE=/ergo"
  say "ergo clone $DIFFRUN_ERGO_CLONE -> /ergo"
fi
# other PEERYARD_*/DIFFRUN_* settings, as they are
for kv in $(env | grep -E '^(PEERYARD|DIFFRUN)_[A-Z0-9_]+=' | grep -vE '^(PEERYARD_JAR|DIFFRUN_ERGO_CLONE|PEERYARD_DOCKER_HOME|PEERYARD_DOCKER_IMAGE)=' | cut -d= -f1); do
  CMD="$CMD -e $kv"
done
[ -n "${GH_TOKEN:-}" ] && { CMD="$CMD -e GH_TOKEN"; say "GH_TOKEN passed through (gh inside the container)"; }
CMD="$CMD $(q "$IMAGE")"
if [ $# -gt 0 ]; then for w in "$@"; do CMD="$CMD $(q "$w")"; done; say "running: $*"; else say "a shell at /peeryard; start with: bash rig/preflight.sh"; fi
say "$CMD"
[ "$DRY" = 1 ] && exit 0
eval "exec $CMD"
