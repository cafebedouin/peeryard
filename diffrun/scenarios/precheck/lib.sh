# shellcheck shell=bash
# lib.sh: shared by the rig-based prechecks (sourced, not run).
#
# A precheck follows a smaller contract than a scenario: it takes the jar as argv[1] and WORKDIR from the
# environment, writes only under WORKDIR, exits 0 when the floor holds, and otherwise prints a line containing
# `INCONCLUSIVE: <reason>` and exits 3. run.sh runs it before each scenario run with the same jar; a failure makes
# that run INCONCLUSIVE (setup) and the scenario is not launched.
#
# run_rig_example <example> <pass-marker-regex> <jar>
#   Runs rig/examples/<example>.{json,sh} on the jar, with the rig's SCRATCH under WORKDIR so that every node
#   process carries WORKDIR in its command line (run.sh's leftover check relies on that). Passes when the rig
#   exits 0 and the hook's output matches the marker.
run_rig_example(){ local name="$1" marker="$2" jar="$3" here rig out rc
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  rig="$(realpath -e "$here/../../../rig" 2>/dev/null)" || { echo "INCONCLUSIVE: precheck: rig/ not found beside diffrun/"; exit 3; }
  [[ -f "$rig/examples/$name.json" && -f "$rig/examples/$name.sh" ]] || { echo "INCONCLUSIVE: precheck: rig example $name not found"; exit 3; }
  jar="$(readlink -f "$jar")"; [[ -f "$jar" ]] || { echo "INCONCLUSIVE: precheck: no jar: $jar"; exit 3; }
  WORKDIR="${WORKDIR:-$(mktemp -d)}"; mkdir -p "$WORKDIR"; WORKDIR="$(readlink -f "$WORKDIR")"; out="$WORKDIR/rig-$name.txt"
  echo "[precheck] rig example $name on $(basename "$jar") sha256=$(sha256sum "$jar" | cut -c1-16)"
  PEERYARD_JAR="$jar" SCRATCH="$WORKDIR/scratch" bash "$rig/rig.sh" "$rig/examples/$name.json" "$rig/examples/$name.sh" > "$out" 2>&1
  rc=$?
  if [[ $rc == 0 ]] && grep -qE "$marker" "$out"; then echo "[precheck] $name PASS"; exit 0; fi
  echo "INCONCLUSIVE: precheck $name failed (rig exit $rc): $(grep -m1 -E 'FAIL|BROKEN|WARN|missing|no node jar|unavailable' "$out" || tail -1 "$out")"
  echo "[precheck] rig output: $out"; exit 3
}
