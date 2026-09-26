#!/usr/bin/env bash
# precheck/floor.sh: the rig's floor as a diffrun precheck. A sole-peer follower must fully sync, and a restarted
# node must keep its chain. An induced failure only means something if the undisturbed network normally works,
# so a run whose floor is broken is INCONCLUSIVE (setup) instead of counting.
#   bash diffrun/scenarios/precheck/floor.sh <jar>      (WORKDIR from the environment; 2-3 minutes)
set -uo pipefail
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
run_rig_example floor 'FLOOR HOLDS' "${1:?usage: $0 <jar>}"
