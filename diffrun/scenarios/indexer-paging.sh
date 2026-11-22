#!/usr/bin/env bash
# indexer-paging: /blockchain/box/unspent/byAddress paging with mempool boxes, on two indexing nodes. A miner M (this
# role's jar) feeds X (this role's jar) and Y (the other role's jar), both with extraIndex; X's address gets 5 confirmed
# and 3 mempool boxes, then each node's listing is paged at limits 1, 2, 3 in both directions, with and without
# includeUnconfirmed, and checked against its own one-page listing; the one-page listings are compared across the jars.
# Built on the rig: the topology is rig/examples/indexer-diff.json, the hook rig/examples/indexer-paging.sh. The base
# role puts the candidate on Y and the candidate role puts the base there.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=diffrun/scenarios/lib/rig-scenario.sh
source "$here/lib/rig-scenario.sh"
run_rig_scenario "$here/../../rig/examples/indexer-diff.json" "$here/../../rig/examples/indexer-paging.sh" "$1"
