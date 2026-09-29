# matrix-txload: transactions in input blocks across two hops. Three Matrix-line nodes in a line, A - B - C, links as in
# matrix-latency (150 ms delay, 100 ms jitter). A mines and pays B in bursts, so input blocks carry transactions, some
# more than three (a miner sends up to three weak transaction ids with the input block; for more, the recipient asks
# for them). Each accepted payment is written to $RIG_LOG_DIR/payments.jsonl ({t_ms, id, burst}); with the wire
# observer on (PEERYARD_WIRE=1), diag/matrix_tx.py reads that file and messages.jsonl and reports, per payment, how it
# reached B and C inside an input block (already in the mempool, or asked for) and when. Honest nodes, benign load.
#   PEERYARD_WIRE=1 PEERYARD_MATRIX_JAR=<weak-blocks jar> bash rig/rig.sh rig/examples/matrix-txload.json rig/examples/matrix-txload.sh
# Env: MATRIX_TXLOAD_BURSTS (8) bursts of MATRIX_TXLOAD_BURST (5) payments, MATRIX_TXLOAD_GAP_S (6) seconds apart,
# MATRIX_TXLOAD_NANOERG (0.1 ERG) each; MATRIX_TXLOAD_WAIT_S (240) for every payment to be confirmed.
# PASS = at least 90% of the payments were accepted (distinct ids), every accepted payment is in an ordering block of C's chain,
# and A and C agree by header id and, with A paused, by state root. The input-block transaction path is reported
# (diag/matrix_tx.py), not judged.
BURSTS=${MATRIX_TXLOAD_BURSTS:-8}; BURST=${MATRIX_TXLOAD_BURST:-5}; GAP=${MATRIX_TXLOAD_GAP_S:-6}
AMT=${MATRIX_TXLOAD_NANOERG:-100000000}; WAIT=${MATRIX_TXLOAD_WAIT_S:-240}; N=$((BURSTS * BURST))
PAY_LOG="$RIG_LOG_DIR/payments.jsonl"; : > "$PAY_LOG"
echo "[matrix-txload] A=$(rest A /info | jq -r .appVersion); $BURSTS bursts of $BURST payments, ${GAP} s apart; waiting for A's reward to mature"
[[ "$(address A)" != "$(address B)" ]] || { echo "[matrix-txload] FAIL: A and B share an address (the mnemonic override did not apply)"; rig_verdict=FAIL; return; }
wait_balance A $((AMT * N * 4 + 1000000000)) 600 >/dev/null || { echo "[matrix-txload] FAIL: A never had a spendable balance"; rig_verdict=FAIL; return; }
# A's wallet spends one confirmed box per payment in a burst (a payment it cannot fund is rejected with "at least one
# input box"), so the mined rewards alone fund a varying number of payments: split them into N + 10 boxes of three
# payments' worth each, confirmed before the load, so every arm offers the same load
echo "[matrix-txload] $(mint_boxes A 2 $(( (N + 10 + 1) / 2 )) $((AMT * 3)))"
# the load starts once B holds one of A's input blocks: a miner sends an input block only to peers whose last reported
# height is within two of its own, so right after a fast start (the reward wait above) it may send none for a while
ready=0; for _ in $(seq 1 60); do [[ -n "$(input_chain_ids B | head -1)" ]] && { ready=1; break; }; sleep 2; done
[[ $ready == 1 ]] || { echo "[matrix-txload] INCONCLUSIVE: B held none of A's input blocks within 120 s"; rig_verdict=INCONCLUSIVE; return; }
H0=$(full_height A); mark load
# each payment spends one of the confirmed boxes split above (pay_from), so no payment spends another's unconfirmed
# change: a chain of dependent payments is a different load (the miner's handling of it is not what this measures)
# (on the Matrix line the split transactions leave the pool at input-block inclusion, before their ordering block:
# wait for the boxes to be confirmed)
for _ in $(seq 1 90); do
  mapfile -t BOXES < <(wallet A "/wallet/boxes/unspent?minConfirmations=1" | jq -r --argjson v $((AMT * 3)) '.[] | select(.box.value == $v) | .box.boxId')
  [[ ${#BOXES[@]} -ge $N ]] && break; sleep 2; done
[[ ${#BOXES[@]} -ge $N ]] || { echo "[matrix-txload] INCONCLUSIVE: ${#BOXES[@]} confirmed split boxes, need $N"; rig_verdict=INCONCLUSIVE; return; }
declare -a IDS=(); declare -A SEEN=(); rejected=0; dup=0; k=0
for b in $(seq 1 "$BURSTS"); do
  for _ in $(seq 1 "$BURST"); do
    id=$(pay_from A B "$AMT" "${BOXES[$k]}"); k=$((k + 1))
    # the wallet can answer a payment with the id of an earlier one (the same transaction built again): counted once
    if [[ "$id" =~ ^[0-9a-f]{64}$ && -n "${SEEN[$id]:-}" ]]; then dup=$((dup + 1)); echo "  burst $b: payment returned an earlier id ${id:0:12}"
    elif [[ "$id" =~ ^[0-9a-f]{64}$ ]]; then SEEN[$id]=1; IDS+=("$id"); printf '{"t_ms":%s,"id":"%s","burst":%s}\n' "$(date +%s%3N)" "$id" "$b" >> "$PAY_LOG"
    else rejected=$((rejected + 1)); echo "  burst $b: payment rejected: $id"; fi
  done
  sleep "$GAP"
done
mark load-done
echo "[matrix-txload] accepted ${#IDS[@]}/$N ($rejected rejected, $dup repeated an earlier id); waiting up to ${WAIT} s for each to be confirmed on C"
# confirmed on C: listed in a block of C's best chain from the load's start height on (read from C's blocks, not
# from a wallet); each is written to $RIG_LOG_DIR/confirmed.jsonl ({id, height})
CONF_LOG="$RIG_LOG_DIR/confirmed.jsonl"; declare -A CONF=(); end=$((SECONDS + WAIT))
scan_c(){ local h hid; : > "$CONF_LOG"; CONF=()
  for ((h = H0; h <= $(full_height C); h++)); do hid=$(header_at C "$h"); [[ -n "$hid" ]] || continue
    for t in $(rest C "/blocks/$hid" | jq -r '.blockTransactions.transactions[].id' 2>/dev/null); do
      [[ -n "${SEEN[$t]:-}" ]] && { CONF[$t]=$h; printf '{"id":"%s","height":%s}\n' "$t" "$h" >> "$CONF_LOG"; }; done; done; }
while :; do scan_c; [[ ${#CONF[@]} -ge ${#IDS[@]} || $SECONDS -ge $end ]] && break; sleep 10; done
sc=$(same_chain A C); ic=$(same_input_chain_stable A C)
stop_mining A >/dev/null
st=NOHEIGHT; for _ in $(seq 1 30); do st=$(same_state A C); case "$st" in SAME@*|DIFF@*) break ;; esac; sleep 2; done
echo "[matrix-txload] confirmed on C: ${#CONF[@]}/${#IDS[@]}; end: input_chain(A,C)=$ic same_chain=${sc%%:*} same_state=${st%%:*}"
res=FAIL
if [[ ${#IDS[@]} -ge $((N * 9 / 10)) && ${#CONF[@]} -eq ${#IDS[@]} && "${sc%%@*}" == SAME && "${st%%@*}" == SAME ]]; then res=PASS; fi
rig_verdict=$res; echo "[matrix-txload] === MATRIX-TXLOAD: $res ==="; echo "MATRIX-TXLOAD-DONE"
