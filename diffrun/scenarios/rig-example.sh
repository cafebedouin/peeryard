#!/usr/bin/env bash
# rig-example: any rig example of rig/examples/suite.tsv (RIG_EXAMPLE) as a diffrun scenario, every node on this role's
# jar, judged as rig/run-suite.sh judges it (pass = the example's PASS marker and rig exit 0). RIG_EXAMPLE_ENV
# ("KEY:VALUE ...") overrides keys of the example's suite.tsv env. So any example runs before and after a change in
# pr-scenario.yml: scenario=rig-example, scenario_env='RIG_EXAMPLE=<name>'. Built on diffrun/scenarios/lib/rig-scenario.sh
# (run_rig_example); which examples qualify: bash diffrun/scenarios/rig-example.check.sh --list.
set -uo pipefail
# shellcheck source=diffrun/scenarios/lib/rig-scenario.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/rig-scenario.sh"
run_rig_example "$1"
