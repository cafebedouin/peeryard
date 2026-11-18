#!/usr/bin/env bash
# peer-pair-keepup: this role's jar on BOTH nodes of a two-node network (A mines, B dials A), bring-up gate off.
# peer-pair asks whether two jars stay connected; this asks the next question for one jar paired with itself: does
# the syncing node apply the full blocks the miner produces? Every PK_SAMPLE_S seconds for PK_WAIT_S seconds the hook
# reads both nodes' /info (headersHeight, fullHeight); the last sample gives the metrics. kept_up is: B's fullHeight
# is no more than PK_MAX_LAG below A's. The base role is the control (the base jar with itself).
# Built on the rig (diffrun/scenarios/lib/rig-scenario.sh): topology hooks/peer-pair-keepup.json, hook
# hooks/peer-pair-keepup.sh.
set -uo pipefail
# shellcheck source=diffrun/scenarios/lib/rig-scenario.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/rig-scenario.sh"
run_rig_scenario "$(dirname "${BASH_SOURCE[0]}")/hooks/peer-pair-keepup.json" "$(dirname "${BASH_SOURCE[0]}")/hooks/peer-pair-keepup.sh" "$1"
