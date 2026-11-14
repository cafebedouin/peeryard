#!/usr/bin/env bash
# nipopow-cutover: a NiPoPoW proof-form change deployed on a running network. Two serving peers (A, B) build a chain
# past a UTXO snapshot on the base jar, so each holds a proof stored by the base; then the nodes named in UPGRADE are
# restarted in place on this role's jar, and a NiPoPoW-bootstrapping joiner (C) is launched. In the base role nothing
# changes jar (the same restarts, on the base jar: the control). In the candidate role the upgraded nodes run the
# candidate jar and announce NEWVER, and C runs the candidate jar (JOINER=new, announcing NEWVER) or the base jar
# (JOINER=old). Metrics: whether C applies a proof, whether it rejects one, what the upgraded servers have to serve
# and when. Built on the rig (lib/rig-scenario.sh): topology hooks/nipopow-cutover.json, hook hooks/nipopow-cutover.sh.
set -uo pipefail
# shellcheck source=diffrun/scenarios/lib/rig-scenario.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/rig-scenario.sh"
run_rig_scenario "$(dirname "${BASH_SOURCE[0]}")/hooks/nipopow-cutover.json" "$(dirname "${BASH_SOURCE[0]}")/hooks/nipopow-cutover.sh" "$1"
