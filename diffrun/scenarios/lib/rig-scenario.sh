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
#
# Second entry point, run_rig_example "$1" (diffrun/scenarios/rig-example.sh): any rig example of
# rig/examples/suite.tsv, unchanged, as a scenario. The example is named by RIG_EXAMPLE; its suite.tsv row gives the
# PASS marker, the timeout and the extra environment, and RIG_EXAMPLE_ENV ("KEY:VALUE KEY:VALUE", or empty) overrides
# keys that row declares (through rig/suite-env.sh, as sweep.yml's scenario_env does). The rig runs the example's own
# topology with the hook diffrun/scenarios/hooks/rig-example.sh, which records every node's appVersion and then sources
# the example's hook. `pass` is run-suite.sh's PASS: the marker in the rig's output and rig exit 0; a FAIL (rig exit 1)
# or the suite timeout is pass=false; a rig that could not stage the example (exit 2, 3, 10) is INCONCLUSIVE.
# Every JVM node runs this role's jar (PEERYARD_JAR, and PEERYARD_MATRIX_JAR for a Matrix example), so an example
# that needs another artifact (suite.tsv needs other than - or matrix), another node kind, or two jars on one network
# is refused: rig_example_resolve says why, and rig-example.check.sh --list lists what runs.

_rig_dir(){ local here; here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; realpath -e "$here/../../../rig" 2>/dev/null; }

# rig_scenario_launch <topology> <hook> <jar> <timeout_s|""> [KEY=VALUE ...]: start the rig as described above, with
# the extra environment; under `timeout` when a timeout is given. Sets RS_OUT (WORKDIR/rig.txt) and RS_RC (rig.sh's
# exit status, 124/137 after the timeout). Prints the role line first. Exits 3 (INCONCLUSIVE) on a missing input.
rig_scenario_launch(){ local topo="$1" hook="$2" jar="$3" to="$4" rig other; shift 4
  rig="$(_rig_dir)" || { echo "INCONCLUSIVE: rig/ not found beside diffrun/"; exit 3; }
  [[ -f "$topo" && -f "$hook" ]] || { echo "INCONCLUSIVE: topology or hook not found ($topo, $hook)"; exit 3; }
  jar="$(readlink -f "$jar")"; [[ -f "$jar" ]] || { echo "INCONCLUSIVE: no jar: $jar"; exit 3; }
  case "${DIFFRUN_ROLE:-}" in base) other="${DIFFRUN_CANDIDATE_JAR:-$jar}" ;; candidate) other="${DIFFRUN_BASE_JAR:-$jar}" ;; *) other="$jar" ;; esac
  WORKDIR="${WORKDIR:-$(mktemp -d)}"; mkdir -p "$WORKDIR"; WORKDIR="$(readlink -f "$WORKDIR")"; RS_OUT="$WORKDIR/rig.txt"
  echo "[rig-scenario] role=${DIFFRUN_ROLE:-none} jar=$(basename "$jar") ($(sha256sum "$jar" | cut -c1-16)) other=$(basename "$other") ($(sha256sum "$other" | cut -c1-16)) java=$(${PEERYARD_JAVA:-java} -version 2>&1 | head -1)"
  if [[ -n "$to" ]]; then
    env "$@" PEERYARD_JAR="$jar" PEERYARD_JAR_B="$other" SCRATCH="$WORKDIR/scratch" timeout -s TERM -k 30 "$to" bash "$rig/rig.sh" "$topo" "$hook" > "$RS_OUT" 2>&1
  else
    env "$@" PEERYARD_JAR="$jar" PEERYARD_JAR_B="$other" SCRATCH="$WORKDIR/scratch" bash "$rig/rig.sh" "$topo" "$hook" > "$RS_OUT" 2>&1
  fi
  RS_RC=$?
}
# the rig's progress lines, forwarded to the scenario's stdout (never a RESULT_JSON line: the scenario prints its own)
_rig_forward(){ grep -E '^\[|^  ' "$1" | grep -v '^\[rig\] (re)launch' | tail -40; }

run_rig_scenario(){ local topo="$1" hook="$2" jar="$3" line
  rig_scenario_launch "$topo" "$hook" "$jar" ""
  line="$(grep -m1 '^RESULT_JSON ' "$RS_OUT")"
  _rig_forward "$RS_OUT"
  if [[ -z "$line" ]]; then
    echo "INCONCLUSIVE: rig exit $RS_RC, no RESULT_JSON from the hook: $(grep -m1 -E 'INCONCLUSIVE|FAIL|BROKEN|missing|no node jar|unavailable|never answered' "$RS_OUT" || tail -1 "$RS_OUT")"
    echo "[rig-scenario] rig output: $RS_OUT"; exit 3
  fi
  echo "$line"; exit 0
}

# rig_example_resolve <name> <overrides>: check that a suite.tsv example can run with every JVM node on one role's jar
# and resolve it. Sets RX_TOPO, RX_HOOK, RX_MARKER, RX_TIMEOUT, RX_ENV (array of KEY=VALUE), RX_MATRIX (1 when the
# topology's jar is PEERYARD_MATRIX_JAR), RX_EXPERIMENTAL (1 when listed in rig/examples/experimental.txt); returns 1
# with RX_ERR set otherwise. <overrides>: "KEY:VALUE KEY:VALUE" (keys the example's row declares), or empty or "-".
rig_example_resolve(){ local name="$1" ov="${2:-}" rig suite row needs envs jars kinds spec it t
  RX_ERR=""; RX_ENV=(); RX_MATRIX=0; RX_EXPERIMENTAL=0
  rig="$(_rig_dir)" || { RX_ERR="rig/ not found beside diffrun/"; return 1; }
  suite="$rig/examples/suite.tsv"
  [[ -n "$name" ]] || { RX_ERR="RIG_EXAMPLE is not set (a name from rig/examples/suite.tsv)"; return 1; }
  [[ "$name" =~ ^[a-z0-9][a-z0-9-]*$ ]] || { RX_ERR="RIG_EXAMPLE '$name': [a-z0-9-] only"; return 1; }
  row="$(awk -F'\t' -v n="$name" '!/^#/ && NF == 5 && $1 == n' "$suite")"
  [[ -n "$row" ]] || { RX_ERR="'$name' has no row in rig/examples/suite.tsv"; return 1; }
  IFS=$'\t' read -r _ RX_MARKER RX_TIMEOUT envs needs <<< "$row"
  RX_TOPO="$rig/examples/$name.json"; RX_HOOK="$rig/examples/$name.sh"
  [[ -f "$RX_TOPO" && -f "$RX_HOOK" ]] || { RX_ERR="'$name': rig/examples/$name.json or .sh missing"; return 1; }
  [[ "$needs" == - || "$needs" == matrix ]] || { RX_ERR="'$name' needs '$needs' (an artifact other than the role's jar): not runnable with one jar per role"; return 1; }
  # every node a JVM node on one jar reference, PEERYARD_JAR or PEERYARD_MATRIX_JAR (a node's own jar, else the
  # topology's, else PEERYARD_JAR: rig.sh's default)
  # shellcheck disable=SC2016  # jq programs and ${...} literals
  kinds="$(jq -r '[.nodes[] | .kind // "jvm"] | unique | join(",")' "$RX_TOPO" 2>/dev/null)" || { RX_ERR="'$name': topology unreadable"; return 1; }
  [[ "$kinds" == jvm ]] || { RX_ERR="'$name' has node kinds '$kinds' (only jvm nodes run the role's jar)"; return 1; }
  # shellcheck disable=SC2016
  jars="$(jq -r '(.jar // "${PEERYARD_JAR}") as $d | [.nodes[] | .jar // $d] | unique | join(",")' "$RX_TOPO")"
  # shellcheck disable=SC2016
  case "$jars" in
    '${PEERYARD_JAR}') ;;
    '${PEERYARD_MATRIX_JAR}') RX_MATRIX=1 ;;
    *) RX_ERR="'$name' puts jars '$jars' on one network (more than one jar, or a fixed path): not one jar per role"; return 1 ;;
  esac
  if [[ -n "$ov" && "$ov" != - ]]; then
    # the overrides through rig/suite-env.sh (the row must declare each key), on a copy of suite.tsv
    spec=""; for it in $ov; do [[ "$it" == *:* ]] || { RX_ERR="RIG_EXAMPLE_ENV item '$it' is not KEY:VALUE"; return 1; }
      spec+="${spec:+;}${it%%:*}=${it#*:}"; done
    t="$(mktemp)"; cp "$suite" "$t"
    if ! it="$(bash "$rig/suite-env.sh" "$t" "$spec" "$name" 2>&1)"; then rm -f "$t"; RX_ERR="RIG_EXAMPLE_ENV: $it"; return 1; fi
    envs="$(awk -F'\t' -v n="$name" '!/^#/ && NF == 5 && $1 == n { print $4 }' "$t")"; rm -f "$t"
  fi
  [[ "$envs" != - ]] && read -ra RX_ENV <<< "$envs"
  grep -qxF "$name" <(grep -vE '^#|^$' "$rig/examples/experimental.txt" 2>/dev/null) && RX_EXPERIMENTAL=1
  return 0
}

# rig_example_list: every suite.tsv example, "<name>\trunnable" or "<name>\trefused: <why>"
rig_example_list(){ local rig n
  rig="$(_rig_dir)" || { echo "rig/ not found beside diffrun/" >&2; return 2; }
  while read -r n; do
    if rig_example_resolve "$n" ""; then printf '%s\trunnable%s\n' "$n" "$([[ $RX_MATRIX == 1 ]] && echo ' (Matrix line)')"
    else printf '%s\trefused: %s\n' "$n" "$RX_ERR"; fi
  done < <(awk -F'\t' '!/^#/ && NF == 5 { print $1 }' "$rig/examples/suite.tsv")
}

# run_rig_example <jar>: the scenario (see the header). Prints one RESULT_JSON with versions (every node that answered
# /info at the hook's hand-off or after it) and metrics pass, timed_out, rig_exit.
run_rig_example(){ local jar="$1" here hook v vs pass=false timed=false extra=()
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; hook="$here/hooks/rig-example.sh"
  if ! rig_example_resolve "${RIG_EXAMPLE:-}" "${RIG_EXAMPLE_ENV:-}"; then echo "CAUSE SETUP_RIG_EXAMPLE"; echo "INCONCLUSIVE: rig-example: $RX_ERR"; exit 3; fi
  extra=(RIG_EXAMPLE_HOOK="$RX_HOOK" "${RX_ENV[@]}")
  [[ $RX_MATRIX == 1 ]] && extra+=(PEERYARD_MATRIX_JAR="$(readlink -f "$jar")")
  echo "[rig-example] example=${RIG_EXAMPLE} topology=$(sha256sum "$RX_TOPO" | cut -c1-16) hook=$(sha256sum "$RX_HOOK" | cut -c1-16) marker='$RX_MARKER' timeout=${RX_TIMEOUT}s env=${RX_ENV[*]:--}$([[ $RX_MATRIX == 1 ]] && echo ' matrix')$([[ $RX_EXPERIMENTAL == 1 ]] && echo ' (experimental in the suite)')"
  rig_scenario_launch "$RX_TOPO" "$hook" "$jar" "$RX_TIMEOUT" "${extra[@]}"
  # after a timeout the rig may not have stopped its nodes: kill what still carries this run's scratch in its argv
  if [[ $RS_RC == 124 || $RS_RC == 137 ]]; then
    timed=true
    ps -eo pid=,args= | S="$WORKDIR/scratch/" awk -v me="$$" '$1 != me && index($0, ENVIRON["S"]) {print $1}' | xargs -r kill -KILL 2>/dev/null
  fi
  _rig_forward "$RS_OUT"
  case "$RS_RC" in
    0) grep -qE -- "$RX_MARKER" "$RS_OUT" && pass=true ;;
    1|124|137) ;;
    *) echo "INCONCLUSIVE: rig exit $RS_RC (the example was not staged to a verdict): $(grep -m1 -E 'CAUSE|INCONCLUSIVE|FAIL|never answered|missing' "$RS_OUT" || tail -1 "$RS_OUT")"
       echo "[rig-scenario] rig output: $RS_OUT"; exit 3 ;;
  esac
  vs="$(sed -n 's/^\[rig-example\] versions [a-z -]*: //p' "$RS_OUT" | jq -cs 'add // {}' 2>/dev/null)"
  [[ -n "$vs" && "$vs" != '{}' ]] || { echo "INCONCLUSIVE: rig exit $RS_RC, no node reported its appVersion"; exit 3; }
  v="$(jq -cn --argjson vs "$vs" --argjson pass "$pass" --argjson to "$timed" --argjson rc "$RS_RC" --arg jv "$(${PEERYARD_JAVA:-java} -version 2>&1 | head -1)" \
    '{schema_version: 1, scenario: "rig-example", runtime: {java: $jv}, versions: $vs, metrics: {pass: $pass, timed_out: $to, rig_exit: $rc}}')"
  echo "[rig-example] ${RIG_EXAMPLE}: $([[ $pass == true ]] && echo PASS || echo FAIL) (rig exit $RS_RC$([[ $timed == true ]] && echo ", suite timeout ${RX_TIMEOUT}s"))"
  echo "RESULT_JSON $v"; exit 0
}
