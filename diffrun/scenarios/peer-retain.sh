#!/usr/bin/env bash
# peer-retain: a node whose dial to a restarting peer failed: is the peer kept, dialled again and caught up? Three
# nodes on this role's jar; the rig example's own topology and hook (rig/examples/peer-retain.{json,sh}), which print
# RESULT_JSON when DIFFRUN_ROLE is set and nothing when the run cannot tell (INCONCLUSIVE).
#   bash diffrun/scenarios/peer-retain.sh <jar>
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=diffrun/scenarios/lib/rig-scenario.sh
source "$here/lib/rig-scenario.sh"
run_rig_scenario "$here/../../rig/examples/peer-retain.json" "$here/../../rig/examples/peer-retain.sh" "$1"
