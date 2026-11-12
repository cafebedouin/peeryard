#!/usr/bin/env bash
# parse-error-log: what one node logs when its REST port receives input that is not HTTP (ergoplatform/ergo#1318).
# One node on this role's jar, no peers, no mining; the hook sends three probes and reads the node's console log;
# see hooks/parse-error-log.sh.
#   bash diffrun/scenarios/parse-error-log.sh <jar>
set -uo pipefail
# shellcheck source=diffrun/scenarios/lib/rig-scenario.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/rig-scenario.sh"
run_rig_scenario "$(dirname "${BASH_SOURCE[0]}")/hooks/parse-error-log.json" "$(dirname "${BASH_SOURCE[0]}")/hooks/parse-error-log.sh" "$1"
