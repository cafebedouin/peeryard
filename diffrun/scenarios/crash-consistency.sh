#!/usr/bin/env bash
# crash-consistency: a node SIGKILLed at random points while it applies a burst of blocks, restarted from its own disk
# each time, must end where an untouched peer is (same best full block, same UTXO state root at an equal height, REST up,
# no unrecoverable log line). M, R and S all run this role's jar; S is the one killed. Built on the rig: the topology
# and hook are rig/examples/crash-consistency.{json,sh}, the classifier rig/crash-verdict.sh, the description
# rig/CRASH-CONSISTENCY.md. The manifest's env passes the hook's CC_* knobs (role, indexer, kill mode, kill count).
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=diffrun/scenarios/lib/rig-scenario.sh
source "$here/lib/rig-scenario.sh"
run_rig_scenario "$here/../../rig/examples/crash-consistency.json" "$here/../../rig/examples/crash-consistency.sh" "$1"
