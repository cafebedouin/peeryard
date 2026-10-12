#!/usr/bin/env bash
# storage-rent-2598: a miner collecting storage rent itself (ergoplatform/ergo#2598) next to a base-jar follower and a
# candidate-jar follower. C runs this role's jar (argv[1]) with storageRentCollection = true and extraIndex = true; F1
# runs the base jar, F2 the candidate jar with collection off. Both jars must carry the devnet test patches
# (patches/test/: storage period 60 blocks, txRentDistinctOutputs from height 30). The hook is the rig example
# rig/examples/storage-rent-2598.sh (docs/storage-rent.md), which prints RESULT_JSON under diffrun.
set -uo pipefail
# shellcheck source=diffrun/scenarios/lib/rig-scenario.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/rig-scenario.sh"
run_rig_scenario "$(dirname "${BASH_SOURCE[0]}")/hooks/storage-rent-2598.json" "$(dirname "${BASH_SOURCE[0]}")/../../rig/examples/storage-rent-2598.sh" "$1"
