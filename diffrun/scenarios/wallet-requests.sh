#!/usr/bin/env bash
# wallet-requests: the same valid and malformed wallet requests sent to two wallet nodes, one per jar. A miner M (this
# role's jar) funds X (this role's jar) and Y (the other role's jar); each issues one token; then each answers payment,
# issuance, burn and box-collection requests, valid and with malformed token ids, addresses or fields, through
# /wallet/transaction/generate, /wallet/boxes/collect and /wallet/payment/send.
# Built on the rig: the topology is rig/examples/indexer-diff.json, the hook rig/examples/wallet-requests.sh. The base
# role puts the candidate on Y and the candidate role puts the base there.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=diffrun/scenarios/lib/rig-scenario.sh
source "$here/lib/rig-scenario.sh"
run_rig_scenario "$here/../../rig/examples/indexer-diff.json" "$here/../../rig/examples/wallet-requests.sh" "$1"
