#!/usr/bin/env bash
# peer-pair: this role's jar (A, mining) and the other role's jar (B, dials A) on one two-node network, with the
# bring-up gate off. After PP_WAIT_S seconds of their own syncing, each node reports whether it is connected to the
# other, how many messages from the other it could not parse, the penalties and blacklistings it applied, and its
# /peers/blacklisted. The metric `paired` is: each node lists the other as connected and neither blacklisted the
# other. A question about two versions staying connected, before any question about following a chain.
# Built on the rig (diffrun/scenarios/lib/rig-scenario.sh): topology hooks/peer-pair.json, hook hooks/peer-pair.sh.
set -uo pipefail
# shellcheck source=diffrun/scenarios/lib/rig-scenario.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/rig-scenario.sh"
run_rig_scenario "$(dirname "${BASH_SOURCE[0]}")/hooks/peer-pair.json" "$(dirname "${BASH_SOURCE[0]}")/hooks/peer-pair.sh" "$1"
