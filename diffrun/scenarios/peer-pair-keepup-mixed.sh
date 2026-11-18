#!/usr/bin/env bash
# peer-pair-keepup-mixed: as peer-pair-keepup, with the OTHER role's jar on node B. In the base role A (mining) is the
# base jar and B the candidate jar; in the candidate role the reverse. So one dispatch shows a candidate syncing from
# a base miner and a base syncing from a candidate miner. Same hook; topology hooks/peer-pair-keepup-mixed.json.
set -uo pipefail
export PK_SCENARIO=peer-pair-keepup-mixed
# shellcheck source=diffrun/scenarios/lib/rig-scenario.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/rig-scenario.sh"
run_rig_scenario "$(dirname "${BASH_SOURCE[0]}")/hooks/peer-pair-keepup-mixed.json" "$(dirname "${BASH_SOURCE[0]}")/hooks/peer-pair-keepup.sh" "$1"
