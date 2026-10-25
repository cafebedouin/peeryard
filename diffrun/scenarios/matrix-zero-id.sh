#!/usr/bin/env bash
# matrix-zero-id: requests for the all-zero header id (Header.GenesisParentId) on the Matrix line (ergo's weak-blocks),
# three nodes in a line on this role's jar; judged on the followers' expired delivery checks for header 0…0. Built on
# the rig: the topology and hook are rig/examples/matrix-zero-id.{json,sh} (the hook emits RESULT_JSON when
# DIFFRUN_ROLE is set, after an activity floor), the topology's "${PEERYARD_MATRIX_JAR}" is this role's jar.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=diffrun/scenarios/lib/rig-scenario.sh
source "$here/lib/rig-scenario.sh"
PEERYARD_MATRIX_JAR="$(readlink -f "$1")"; export PEERYARD_MATRIX_JAR
run_rig_scenario "$here/../../rig/examples/matrix-zero-id.json" "$here/../../rig/examples/matrix-zero-id.sh" "$1"
