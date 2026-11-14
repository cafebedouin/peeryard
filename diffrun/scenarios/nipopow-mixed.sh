#!/usr/bin/env bash
# nipopow-mixed: a NiPoPoW-bootstrapping joiner (C, the other role's jar) against two serving peers (A, B, this
# role's jar). A mines and mints a prefix past a UTXO snapshot so A and B can serve a NiPoPoW proof; C is launched
# with nipopowBootstrap = true and asks for one. The metric is whether C applies the served proof or rejects it and
# stalls at header height 0. Both arms are mixed (C runs ${PEERYARD_JAR_B}), so base and candidate are the two
# directions of a proof-form change. Built on the rig (diffrun/scenarios/lib/rig-scenario.sh): the topology is
# hooks/nipopow-mixed.json, the hook is hooks/nipopow-mixed.sh.
set -uo pipefail
# shellcheck source=diffrun/scenarios/lib/rig-scenario.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/rig-scenario.sh"
run_rig_scenario "$(dirname "${BASH_SOURCE[0]}")/hooks/nipopow-mixed.json" "$(dirname "${BASH_SOURCE[0]}")/hooks/nipopow-mixed.sh" "$1"
