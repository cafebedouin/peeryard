#!/usr/bin/env bash
# interop: the release jar and the candidate jar on one two-node network. A runs this role's jar (argv[1]) and
# mines while B (the other role's jar) follows; then B mines and A follows. The metric is agreement both ways:
# same header ids and the same UTXO state root at an equal height once the miner pauses. Built on the rig
# (diffrun/scenarios/lib/rig-scenario.sh): the topology is interop.json, the hook is hooks/interop.sh.
set -uo pipefail
# shellcheck source=diffrun/scenarios/lib/rig-scenario.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/rig-scenario.sh"
run_rig_scenario "$(dirname "${BASH_SOURCE[0]}")/hooks/interop.json" "$(dirname "${BASH_SOURCE[0]}")/hooks/interop.sh" "$1"
