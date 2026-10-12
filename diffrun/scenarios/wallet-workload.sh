#!/usr/bin/env bash
# wallet-workload: the scripted wallet workload with invariant checks (rig/WALLET-WORKLOAD.md) as a diffrun scenario.
# M mines on the base jar; the wallet under test, A, runs this role's jar; its twin B (the same mnemonic, the wallet
# restored on a second node) runs the other role's jar, so the resubmit and conflicting-spend steps put both versions
# on one network and ask whether they agree. The manifest's env selects the steps (WW_PRESET / WW_STEPS, WW_CONTROL)
# and names the result (WW_SCENARIO). Built on the rig: topology hooks/wallet-workload.json, hook
# rig/examples/wallet-workload.sh. Same jar in both roles = the A/A control.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=diffrun/scenarios/lib/rig-scenario.sh
source "$here/lib/rig-scenario.sh"
run_rig_scenario "$here/hooks/wallet-workload.json" "$here/../../rig/examples/wallet-workload.sh" "$1"
