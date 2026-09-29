#!/usr/bin/env bash
# matrix-paychain: bursts of ordinary wallet payments on the Matrix line (ergo's weak-blocks), two nodes running this
# role's jar; judged on accepted payments that end neither confirmed nor in the miner's pool (lost). Built on the rig:
# the topology and hook are rig/examples/matrix-paychain.{json,sh} (the hook emits RESULT_JSON when DIFFRUN_ROLE is
# set, after an activity floor), the topology's "${PEERYARD_MATRIX_JAR}" is this role's jar.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=diffrun/scenarios/lib/rig-scenario.sh
source "$here/lib/rig-scenario.sh"
PEERYARD_MATRIX_JAR="$(readlink -f "$1")"; export PEERYARD_MATRIX_JAR
run_rig_scenario "$here/../../rig/examples/matrix-paychain.json" "$here/../../rig/examples/matrix-paychain.sh" "$1"
