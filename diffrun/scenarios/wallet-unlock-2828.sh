#!/usr/bin/env bash
# wallet-unlock-2828: what /wallet/unlock does when the wallet's secret file cannot be read (ergoplatform/ergo#2828).
# One node on this role's jar, no peers, no mining; the hook moves the initialized wallet's secret file away, times the
# unlock, moves it back and unlocks again; see hooks/wallet-unlock-2828.sh.
#   bash diffrun/scenarios/wallet-unlock-2828.sh <jar>
set -uo pipefail
# shellcheck source=diffrun/scenarios/lib/rig-scenario.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/rig-scenario.sh"
run_rig_scenario "$(dirname "${BASH_SOURCE[0]}")/hooks/wallet-unlock-2828.json" "$(dirname "${BASH_SOURCE[0]}")/hooks/wallet-unlock-2828.sh" "$1"
