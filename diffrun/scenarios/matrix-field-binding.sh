#!/usr/bin/env bash
# matrix-field-binding: wallet payments on the Matrix line (ergo's weak-blocks), two nodes on this role's jar; judged on the
# follower's rejections of the miner's input-block announcements by the declared-field check of ergoplatform/ergo#2368.
# The load and topology are rig/examples/matrix-paychain.{json,sh}; the hook is hooks/matrix-field-binding.sh. Both jars
# need that check (as a test patch); a jar without it reports zero whatever the producer does.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=diffrun/scenarios/lib/rig-scenario.sh
source "$here/lib/rig-scenario.sh"
PEERYARD_MATRIX_JAR="$(readlink -f "$1")"; export PEERYARD_MATRIX_JAR
run_rig_scenario "$here/../../rig/examples/matrix-paychain.json" "$here/hooks/matrix-field-binding.sh" "$1"
