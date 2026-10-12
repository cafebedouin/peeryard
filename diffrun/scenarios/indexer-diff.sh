#!/usr/bin/env bash
# indexer-diff: the extra indexer (ergo.node.extraIndex = true) of two jars on one chain. A miner M (this role's jar)
# feeds X (this role's jar) and Y (the other role's jar), both indexing; at settled points their /blockchain/... answers
# are compared field by field (rig/indexer-cmp.sh): after real payments, a token issue and spent boxes; after a restart
# of Y; after Y rolls back a losing branch. A positive control (X's view before a payment against Y's after) must come
# out DIFF or the run is INCONCLUSIVE. Built on the rig: the topology and hook are rig/examples/indexer-diff.{json,sh};
# the topology's Y node runs "${PEERYARD_JAR_B}", which lib/rig-scenario.sh sets to the other role's jar, so the base
# role puts the candidate on Y and the candidate role puts the base there. Same jar in both roles = the A/A control.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=diffrun/scenarios/lib/rig-scenario.sh
source "$here/lib/rig-scenario.sh"
run_rig_scenario "$here/../../rig/examples/indexer-diff.json" "$here/../../rig/examples/indexer-diff.sh" "$1"
