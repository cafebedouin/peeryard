# matrix-txload: transactions in input blocks across two hops. Three Matrix-line nodes in a line, A - B - C, links as in
# matrix-latency (150 ms delay, 100 ms jitter). A mines and pays B in bursts, so input blocks carry transactions, some
# more than three (a miner sends up to three weak transaction ids with the input block; for more, the recipient asks
# for them). Each accepted payment is written to $RIG_LOG_DIR/payments.jsonl ({t_ms, id, burst}); with the wire
# observer on (PEERYARD_WIRE=1), diag/matrix_tx.py reads that file and messages.jsonl and reports, per payment, how it
# reached B and C inside an input block (already in the mempool, or asked for) and when. Honest nodes, benign load.
#   PEERYARD_WIRE=1 PEERYARD_MATRIX_JAR=<weak-blocks jar> bash rig/rig.sh rig/examples/matrix-txload.json rig/examples/matrix-txload.sh
# Env: MATRIX_TXLOAD_BURSTS (8) bursts of MATRIX_TXLOAD_BURST (5) payments, MATRIX_TXLOAD_GAP_S (6) seconds apart,
# MATRIX_TXLOAD_NANOERG (0.1 ERG) each; MATRIX_TXLOAD_WAIT_S (240) for every payment to be confirmed.
# PASS = at least 90% of the payments were accepted, every accepted payment is in an ordering block of C's chain,
# and A and C agree by header id and, with A paused, by state root. The input-block transaction path is reported
# (diag/matrix_tx.py), not judged.
BURSTS=${MATRIX_TXLOAD_BURSTS:-8}; BURST=${MATRIX_TXLOAD_BURST:-5}; GAP=${MATRIX_TXLOAD_GAP_S:-6}
AMT=${MATRIX_TXLOAD_NANOERG:-100000000}; WAIT=${MATRIX_TXLOAD_WAIT_S:-240}; N=$((BURSTS * BURST))
PAY_LOG="$RIG_LOG_DIR/payments.jsonl"; : > "$PAY_LOG"
echo "[matrix-txload] A=$(rest A /info | jq -r .appVersion); $BURSTS bursts of $BURST payments, ${GAP} s apart; waiting for A's reward to mature"
[[ "$(address A)" != "$(address B)" ]] || { echo "[matrix-txload] FAIL: A and B share an address (the mnemonic override did not apply)"; rig_verdict=FAIL; return; }
wait_balance A $((AMT * N * 2 + 1000000000)) 600 >/dev/null || { echo "[matrix-txload] FAIL: A never had a spendable balance"; rig_verdict=FAIL; return; }
mark load
declare -a IDS; rejected=0
for b in $(seq 1 "$BURSTS"); do
  for _ in $(seq 1 "$BURST"); do
    id=$(pay A B "$AMT")
    if [[ "$id" =~ ^[0-9a-f]{64}$ ]]; then IDS+=("$id"); printf '{"t_ms":%s,"id":"%s","burst":%s}\n' "$(date +%s%3N)" "$id" "$b" >> "$PAY_LOG"
    else rejected=$((rejected + 1)); echo "  burst $b: payment rejected: $id"; fi
  done
  sleep "$GAP"
done
mark load-done
echo "[matrix-txload] accepted ${#IDS[@]}/$N ($rejected rejected); waiting up to ${WAIT} s for each to be confirmed on C"
# confirmed on C: B's wallet reports the inclusion height, and the block C holds at that height lists the payment
on_c(){ local ih hid; ih=$(wallet B "/wallet/transactionById?id=$1" | jq -r '.inclusionHeight // empty' 2>/dev/null)
  [[ -n "$ih" ]] || return 1; hid=$(header_at C "$ih"); [[ -n "$hid" ]] || return 1
  rest C "/blocks/$hid" | jq -e --arg t "$1" '[.blockTransactions.transactions[].id] | index($t) != null' >/dev/null 2>&1; }
declare -A CONF; end=$((SECONDS + WAIT))
while [[ $SECONDS -lt $end && ${#CONF[@]} -lt ${#IDS[@]} ]]; do
  for id in "${IDS[@]}"; do [[ -n "${CONF[$id]:-}" ]] || { on_c "$id" && CONF[$id]=1; }; done
  [[ ${#CONF[@]} -lt ${#IDS[@]} ]] && sleep 5
done
sc=$(same_chain A C); ic=$(same_input_chain_stable A C)
stop_mining A >/dev/null
st=NOHEIGHT; for _ in $(seq 1 30); do st=$(same_state A C); case "$st" in SAME@*|DIFF@*) break ;; esac; sleep 2; done
echo "[matrix-txload] confirmed on C: ${#CONF[@]}/${#IDS[@]}; end: input_chain(A,C)=$ic same_chain=${sc%%:*} same_state=${st%%:*}"
res=FAIL
if [[ ${#IDS[@]} -ge $((N * 9 / 10)) && ${#CONF[@]} -eq ${#IDS[@]} && "${sc%%@*}" == SAME && "${st%%@*}" == SAME ]]; then res=PASS; fi
rig_verdict=$res; echo "[matrix-txload] === MATRIX-TXLOAD: $res ==="; echo "MATRIX-TXLOAD-DONE"
