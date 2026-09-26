#!/usr/bin/env bash
# run-suite.sh: run rig examples from rig/examples/suite.tsv and report one line per example.
#
#   PEERYARD_JAR=<node jar> bash rig/run-suite.sh [--out DIR] [name ...]     (no names: every example)
#
# Each example runs through rig/rig.sh with its timeout and extra environment from suite.tsv; its output goes to
# DIR/rig_<name>.txt (default DIR: ./suite-out) and the line `rig <name>: PASS (<marker>)` or `rig <name>: FAIL (...)`
# is printed. An example whose artefacts are not set is reported `SKIP (needs ...)`, not run:
#   release          PEERYARD_JAR_RELEASE   the plain release jar (the `mixed` example's follower)
#   matrix           PEERYARD_MATRIX_JAR    a Matrix (weak-blocks) build
#   arkadianet       PEERYARD_ARKADIANET_BIN
#   arkadianet-magic PEERYARD_ARKADIANET_MAGIC_BIN (a build that accepts the magic override; defaults to the above)
#   ergo-node-rust   PEERYARD_ERGO_NODE_RUST_BIN
# PASS needs the marker and rig.sh's exit status 0 (a harness failure makes rig.sh exit 3).
# Exit status: 0 when every example that ran passed, 1 otherwise.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; ROOT="$(dirname "$HERE")"
OUT="suite-out"; [[ "${1:-}" == --out ]] && { OUT="$2"; shift 2; }
[[ -n "${PEERYARD_JAR:-}" ]] || { echo "run-suite: set PEERYARD_JAR to the node jar" >&2; exit 2; }
mkdir -p "$OUT"; OUT="$(cd "$OUT" && pwd)"
PEERYARD_ARKADIANET_MAGIC_BIN="${PEERYARD_ARKADIANET_MAGIC_BIN:-${PEERYARD_ARKADIANET_BIN:-}}"
want=" $* "; failed=0; ran=0; matched=0
for n in "$@"; do
  grep -q "^$n"$'\t' "$HERE/examples/suite.tsv" || { echo "run-suite: unknown example '$n' (see rig/examples/suite.tsv)" >&2; exit 2; }
done
artefact(){ case "$1" in
  release) echo "${PEERYARD_JAR_RELEASE:-}" ;; matrix) echo "${PEERYARD_MATRIX_JAR:-}" ;;
  arkadianet) echo "${PEERYARD_ARKADIANET_BIN:-}" ;; arkadianet-magic) echo "${PEERYARD_ARKADIANET_MAGIC_BIN:-}" ;;
  ergo-node-rust) echo "${PEERYARD_ERGO_NODE_RUST_BIN:-}" ;; *) echo "" ;; esac; }
# rig/examples/experimental.txt: examples whose FAIL is reported but not counted (a measured, documented pass rate
# below 100% on some hosts; rig/README.md says which and why). They still run, and a PASS is still a PASS.
experimental="$(grep -vE '^#|^$' "$HERE/examples/experimental.txt" 2>/dev/null | tr '\n' ' ')"
while IFS=$'\t' read -r name marker to envs needs; do
  [[ -z "$name" || "$name" == \#* ]] && continue
  [[ "$want" == "  " || "$want" == *" $name "* ]] || continue
  matched=$((matched + 1))
  missing=""
  if [[ "$needs" != - ]]; then
    IFS=, read -ra ns <<<"$needs"
    for n in "${ns[@]}"; do a="$(artefact "$n")"; [[ -n "$a" && -e "$a" ]] || missing+="$n "; done
  fi
  if [[ -n "$missing" ]]; then echo "rig $name: SKIP (needs ${missing% })"; continue; fi
  extra=(); [[ "$envs" != - ]] && read -ra extra <<<"$envs"
  case ",$needs," in *,release,*) extra+=("PEERYARD_JAR_B=$PEERYARD_JAR_RELEASE") ;; esac
  case ",$needs," in *,arkadianet-magic,*) extra+=("PEERYARD_ARKADIANET_BIN=$PEERYARD_ARKADIANET_MAGIC_BIN") ;; esac
  ran=$((ran + 1))
  ( cd "$ROOT" && env ${extra[@]+"${extra[@]}"} timeout "$to" bash rig/rig.sh "rig/examples/$name.json" "rig/examples/$name.sh" ) \
    > "$OUT/rig_$name.txt" 2>&1
  rc=$?
  # PASS needs the example's marker AND the rig's exit status 0: a harness failure (rig.sh exit 3) voids a marker
  exp=""; [[ " $experimental " == *" $name "* ]] && exp=" (experimental)"
  if [[ $rc -eq 0 ]] && grep -qE "$marker" "$OUT/rig_$name.txt"; then echo "rig $name: PASS$exp ($marker)"
  else
    case $rc in 0) why="marker '$marker' absent" ;; 1) why="FAIL" ;; 3) why="INCONCLUSIVE: $(grep -m1 -o 'CAUSE .*' "$OUT/rig_$name.txt" || echo 'no cause line')" ;;
      124) why="TIMEOUT after ${to}s" ;; *) why="exit $rc" ;; esac
    if [[ -n "$exp" ]]; then echo "rig $name: FAIL$exp ($why; not counted; see $OUT/rig_$name.txt)"
    else echo "rig $name: FAIL ($why; see $OUT/rig_$name.txt)"; failed=$((failed + 1)); fi
    # keep the node logs of a run that did not PASS beside its output (the rig's scratch is not deleted, but a CI
    # artifact carries only --out): <OUT>/logs_<name>/<node>.log and the rig's probe.log
    sc="$(grep -m1 -o '^\[rig\] scratch: .*' "$OUT/rig_$name.txt" | cut -d' ' -f3)"
    if [[ -n "$sc" && -d "$sc" ]]; then mkdir -p "$OUT/logs_$name"
      for l in "$sc"/rt_*/ergo.log "$sc"/rt_*/*.log "$sc"/probe.log; do [[ -f "$l" ]] || continue
        n="$(basename "$(dirname "$l")")"; n="${n#rt_}"; cp "$l" "$OUT/logs_$name/${n}_$(basename "$l")"; done
      echo "  node logs kept: $OUT/logs_$name/"
    fi
  fi
done < "$HERE/examples/suite.tsv"
[[ $failed -eq 0 ]]
