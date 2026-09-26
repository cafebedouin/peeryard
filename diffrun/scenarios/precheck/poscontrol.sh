#!/usr/bin/env bash
# precheck/poscontrol.sh: the rig's positive control as a diffrun precheck. Two miners that never peer must end up
# on different chains and `same_chain` must report DIFF. If the comparator cannot see a difference here, a
# scenario's "no divergence" means nothing, so the run is INCONCLUSIVE (setup) instead of counting.
#   bash diffrun/scenarios/precheck/poscontrol.sh <jar>      (WORKDIR from the environment; ~1 minute)
set -uo pipefail
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
run_rig_example poscontrol 'OBSERVER-POSCTRL PASS' "${1:?usage: $0 <jar>}"
