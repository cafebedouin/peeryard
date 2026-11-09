# shellcheck shell=bash
# matrix-field-binding: the load of rig/examples/matrix-paychain.sh, then one result counted from the follower's log: how
# many of the miner's input-block announcements its validation rejected because a declared field is not among the
# proven extension leaves (ergoplatform/ergo#2368's check). Only meaningful on a jar that has that check. A follower that
# processed fewer than MATRIX_FIELD_BINDING_FLOOR valid or rejected announcements (default 20) is INCONCLUSIVE.
PAYCHAIN="$(dirname "$(readlink -f "$HOOK")")/../../../rig/examples/matrix-paychain.sh"
role="${DIFFRUN_ROLE:-}"; unset DIFFRUN_ROLE
HOOK="$(readlink -f "$PAYCHAIN")"   # the paychain hook finds diag/ relative to itself
# shellcheck source=/dev/null
source "$PAYCHAIN"
[[ "${rig_verdict:-}" != INCONCLUSIVE ]] || return
log="$RIG_LOG_DIR/node_B.log"
count(){ grep -cE "$1" "$log"; }
not_bound=$(count 'Input block fields are not bound to extension proof')
invalid=$(count 'Sub-block .* is invalid')
valid=$(count 'Processing valid sub-block')
with_txs=$(grep 'Processing valid sub-block' "$log" | grep -cE 'weak txs announced: Some\([1-9][0-9]*\)')
floor=${MATRIX_FIELD_BINDING_FLOOR:-20}
echo "[matrix-field-binding] not_bound=$not_bound invalid=$invalid valid=$valid with_txs=$with_txs"
if (( valid + invalid < floor )); then
  echo "[matrix-field-binding] INCONCLUSIVE: $((valid + invalid)) announcements < floor $floor"; rig_verdict=INCONCLUSIVE; return
fi
rig_verdict=PASS
if [[ -n "$role" ]]; then
  counts=$(python3 "$(dirname "$HOOK")/../../diag/matrix_paychain.py" --json "$RIG_LOG_DIR") || { rig_verdict=INCONCLUSIVE; return; }
  echo "RESULT_JSON $(jq -cn --arg A "$VA" --arg B "$VB" --argjson c "$counts" --argjson nb "$not_bound" --argjson inv "$invalid" \
    --argjson val "$valid" --argjson wt "$with_txs" \
    '{schema_version: 1, scenario: "matrix-field-binding", versions: {A: $A, B: $B},
      metrics: {not_bound: $nb, invalid: $inv, valid: $val, with_txs: $wt, accepted: $c.accepted, lost: $c.lost}}')"
fi
