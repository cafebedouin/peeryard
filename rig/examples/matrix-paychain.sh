# matrix-paychain: bursts of ordinary wallet payments on the Matrix line (ergo's `weak-blocks`), where the wallet may
# spend the change of a payment that is not confirmed yet. A mines and pays B; B follows. Two nodes, one link, 0 ms.
#   PEERYARD_MATRIX_JAR=<weak-blocks jar> bash rig/rig.sh rig/examples/matrix-paychain.json rig/examples/matrix-paychain.sh
# Load: A's rewards are split (one transaction) into N + 10 confirmed boxes (three payments' worth each), then BURSTS bursts of BURST
# payments of 0.1 ERG, GAP s apart, through /wallet/payment/send (the wallet chooses the inputs). Env:
# MATRIX_PAYCHAIN_BURSTS (8), MATRIX_PAYCHAIN_BURST (5), MATRIX_PAYCHAIN_GAP_S (6), MATRIX_PAYCHAIN_WAIT_S (240).
# Per payment, $RIG_LOG_DIR/payments.jsonl records {t_ms, id, burst, inputs, outputs} as A's pool lists it right after
# the send; confirmed.jsonl the payments found in B's blocks; a_pool_end.txt A's pool at the end.
# A payment is DEPENDENT when an input is an output of an earlier payment of this run (unconfirmed change), and LOST
# when it is neither in a block of B's chain nor in A's pool once the wait is over.
# PASS = every accepted payment is confirmed. The last line is machine-readable:
#   MATRIX-PAYCHAIN accepted=<n> dependent=<n> confirmed=<n> dependent_confirmed=<n> lost=<n> dependent_lost=<n> pending=<n> verdict=<PASS|FAIL>
BURSTS=${MATRIX_PAYCHAIN_BURSTS:-8}; BURST=${MATRIX_PAYCHAIN_BURST:-5}; GAP=${MATRIX_PAYCHAIN_GAP_S:-6}
WAIT=${MATRIX_PAYCHAIN_WAIT_S:-240}; AMT=100000000; N=$((BURSTS * BURST))
PAY_LOG="$RIG_LOG_DIR/payments.jsonl"; CONF_LOG="$RIG_LOG_DIR/confirmed.jsonl"; : > "$PAY_LOG"; : > "$CONF_LOG"
echo "[matrix-paychain] A=$(rest A /info | jq -r .appVersion) B=$(rest B /info | jq -r .appVersion); $BURSTS bursts of $BURST, ${GAP} s apart"
[[ "$(address A)" != "$(address B)" ]] || { echo "[matrix-paychain] FAIL: A and B share an address"; rig_verdict=FAIL; return; }
wait_balance A $((AMT * N * 4 + 1000000000)) 600 >/dev/null || { echo "[matrix-paychain] FAIL: A never had a spendable balance"; rig_verdict=FAIL; return; }
# one split transaction: two back to back would make the second spend the first's unconfirmed change, the case
# this example measures, and the miner may drop it (then the load never starts)
echo "[matrix-paychain] $(mint_boxes A 1 $((N + 10)) $((AMT * 3)))"
# the split boxes confirmed, B at A's height, and B holding one of A's input blocks (a miner sends input blocks only
# to peers whose last reported height is within two of its own)
ready=0; for _ in $(seq 1 90); do
  nb=$(wallet A "/wallet/boxes/unspent?minConfirmations=1" | jq --argjson v $((AMT * 3)) '[.[] | select(.box.value == $v)] | length' 2>/dev/null)
  ha=$(full_height A); hb=$(full_height B)
  if [[ "${nb:-0}" -ge $N && -n "$ha" && "$ha" == "$hb" && -n "$(input_chain_ids B | head -1)" ]]; then ready=1; break; fi
  sleep 2; done
[[ $ready == 1 ]] || { echo "[matrix-paychain] INCONCLUSIVE: not ready within 180 s (split boxes ${nb:-0}/$N, heights A=$ha B=$hb)"; rig_verdict=INCONCLUSIVE; return; }
H0=$(full_height A); mark load
declare -a IDS=(); declare -A SEEN=(); rejected=0
for b in $(seq 1 "$BURSTS"); do
  for _ in $(seq 1 "$BURST"); do
    id=$(pay A B "$AMT")
    if [[ "$id" =~ ^[0-9a-f]{64}$ && -z "${SEEN[$id]:-}" ]]; then SEEN[$id]=1; IDS+=("$id")
      tx=$(rest A "/transactions/unconfirmed/byTransactionId/$id")
      ins=$(jq -c '[.inputs[]?.boxId]' <<< "$tx" 2>/dev/null); outs=$(jq -c '[.outputs[]?.boxId]' <<< "$tx" 2>/dev/null)
      printf '{"t_ms":%s,"id":"%s","burst":%s,"inputs":%s,"outputs":%s}\n' "$(date +%s%3N)" "$id" "$b" "${ins:-null}" "${outs:-null}" >> "$PAY_LOG"
    elif [[ ! "$id" =~ ^[0-9a-f]{64}$ ]]; then rejected=$((rejected + 1)); echo "  burst $b: rejected: ${id:0:120}"; fi
  done
  sleep "$GAP"
done
mark load-done
echo "[matrix-paychain] accepted ${#IDS[@]}/$N ($rejected rejected); waiting up to ${WAIT} s for each to be in a block of B's chain"
declare -A CONF=(); end=$((SECONDS + WAIT))
scan(){ local h hid t; : > "$CONF_LOG"; CONF=()
  for ((h = H0; h <= $(full_height B); h++)); do hid=$(header_at B "$h"); [[ -n "$hid" ]] || continue
    for t in $(rest B "/blocks/$hid" | jq -r '.blockTransactions.transactions[].id' 2>/dev/null); do
      [[ -n "${SEEN[$t]:-}" ]] && { CONF[$t]=$h; printf '{"id":"%s","height":%s}\n' "$t" "$h" >> "$CONF_LOG"; }; done; done; }
while :; do scan; [[ ${#CONF[@]} -ge ${#IDS[@]} || $SECONDS -ge $end ]] && break; sleep 10; done
mempool_ids A > "$RIG_LOG_DIR/a_pool_end.txt"
# dependent / lost, from the recorded inputs and outputs (diag/matrix_paychain.py)
line=$(python3 "$(dirname "$(readlink -f "$HOOK")")/../../diag/matrix_paychain.py" "$RIG_LOG_DIR") || line="classification failed"
res=FAIL; [[ ${#IDS[@]} -gt 0 && ${#CONF[@]} -eq ${#IDS[@]} ]] && res=PASS
rig_verdict=$res
echo "$line verdict=$res"
