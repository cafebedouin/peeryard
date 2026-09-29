# shellcheck shell=bash
# rig-scenario.sh: write a diffrun scenario as a rig topology plus a rig hook (sourced, not run).
#
# A scenario built on this library is a 10-line script:
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/rig-scenario.sh"
#   run_rig_scenario <topology.json> <hook.sh> "$1"
# The library starts rig/rig.sh (beside diffrun/) on the topology with SCRATCH under WORKDIR, so every node
# process carries WORKDIR in its command line (run.sh's leftover check relies on that), and with:
#   PEERYARD_JAR     = the jar diffrun passed as argv[1] (this role's jar),
#   PEERYARD_JAR_B   = the other role's jar (DIFFRUN_BASE_JAR when this role is the candidate, and the other
#                       way round), so a topology may put both jars on one network with "jar": "${PEERYARD_JAR_B}".
# The hook has every rig helper (rest, same_chain, same_state, mine, pay, ...) and must print exactly one
# `RESULT_JSON {...}` line (the scenario contract, diffrun/README.md) and set rig_verdict. The library forwards
# that line and exits 0; if the rig fails to bring the network up, or the hook prints no result line, it prints
# `INCONCLUSIVE: <reason>` and exits 3. The rig's own output goes to WORKDIR/rig.txt.
run_rig_scenario(){ local topo="$1" hook="$2" jar="$3" here rig out rc other line
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  rig="$(realpath -e "$here/../../../rig" 2>/dev/null)" || { echo "INCONCLUSIVE: rig/ not found beside diffrun/"; exit 3; }
  [[ -f "$topo" && -f "$hook" ]] || { echo "INCONCLUSIVE: topology or hook not found ($topo, $hook)"; exit 3; }
  jar="$(readlink -f "$jar")"; [[ -f "$jar" ]] || { echo "INCONCLUSIVE: no jar: $jar"; exit 3; }
  case "${DIFFRUN_ROLE:-}" in base) other="${DIFFRUN_CANDIDATE_JAR:-$jar}" ;; candidate) other="${DIFFRUN_BASE_JAR:-$jar}" ;; *) other="$jar" ;; esac
  WORKDIR="${WORKDIR:-$(mktemp -d)}"; mkdir -p "$WORKDIR"; WORKDIR="$(readlink -f "$WORKDIR")"; out="$WORKDIR/rig.txt"
  echo "[rig-scenario] role=${DIFFRUN_ROLE:-none} jar=$(basename "$jar") ($(sha256sum "$jar" | cut -c1-16)) other=$(basename "$other") ($(sha256sum "$other" | cut -c1-16)) java=$(${PEERYARD_JAVA:-java} -version 2>&1 | head -1)"
  PEERYARD_JAR="$jar" PEERYARD_JAR_B="$other" SCRATCH="$WORKDIR/scratch" bash "$rig/rig.sh" "$topo" "$hook" > "$out" 2>&1
  rc=$?
  line="$(grep -m1 '^RESULT_JSON ' "$out")"
  grep -E '^\[|^  ' "$out" | grep -v '^\[rig\] (re)launch' | tail -40
  if [[ -z "$line" ]]; then
    echo "INCONCLUSIVE: rig exit $rc, no RESULT_JSON from the hook: $(grep -m1 -E 'INCONCLUSIVE|FAIL|BROKEN|missing|no node jar|unavailable|never answered' "$out" || tail -1 "$out")"
    echo "[rig-scenario] rig output: $out"; exit 3
  fi
  echo "$line"; exit 0
}
