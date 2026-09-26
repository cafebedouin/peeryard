#!/usr/bin/env bash
# bootstrap-modes.sh: diffrun scenario on the rig (diffrun/scenarios/lib/rig-scenario.sh). One miner and two
# followers, all on this role's jar: B in digest mode, C pruning full blocks (blocksToKeep 20). The hook is the
# rig example of the same name with a RESULT_JSON line; see hooks/bootstrap-modes.sh.
#   bash diffrun/scenarios/bootstrap-modes.sh <jar>
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/lib/rig-scenario.sh"
run_rig_scenario "$HERE/hooks/bootstrap-modes.json" "$HERE/hooks/bootstrap-modes.sh" "$1"
