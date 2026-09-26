#!/usr/bin/env bash
# txload: real payments on a two-node network running this role's jar: A mines into its wallet, waits out the
# reward delay, pays B ten times; the payments must be accepted, confirm into B's balance, and appear in blocks.
# Built on the rig (diffrun/scenarios/lib/rig-scenario.sh): topology hooks/txload.json, hook hooks/txload.sh.
set -uo pipefail
# shellcheck source=diffrun/scenarios/lib/rig-scenario.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/rig-scenario.sh"
run_rig_scenario "$(dirname "${BASH_SOURCE[0]}")/hooks/txload.json" "$(dirname "${BASH_SOURCE[0]}")/hooks/txload.sh" "$1"
