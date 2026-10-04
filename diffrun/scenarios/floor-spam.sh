#!/usr/bin/env bash
# relay-floor: a relay with a lower fee floor than its neighbours, under real wallet load, five nodes running
# this role's jar; judged on valid payments relayed through it that reach the strict node only after the next block.
# Built on the rig: the topology and hook are rig/examples/relay-floor.{json,sh} (the hook emits RESULT_JSON when
# DIFFRUN_ROLE is set, after an activity floor).
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=diffrun/scenarios/lib/rig-scenario.sh
source "$here/lib/rig-scenario.sh"
run_rig_scenario "$here/../../rig/examples/relay-floor.json" "$here/../../rig/examples/relay-floor.sh" "$1"
