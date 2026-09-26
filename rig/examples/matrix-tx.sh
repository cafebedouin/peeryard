# matrix-tx: transactions on the Matrix line (ergo's `weak-blocks`, sub-blocks). A mines, B follows (its own wallet).
# A pays B N times; for each payment the hook records when it first sits in an input block on A, when B holds that
# input block with the payment in it, and when an ordering block confirms it (in the block A holds at the height
# B's wallet reports). Chain: the `matrix` preset with a 20 s ordering interval, so input blocks exist (see
# matrix-pair). Env: MATRIX_TX_N (5), MATRIX_TX_NANOERG (0.1 ERG), MATRIX_TX_WAIT_S per payment (180).
#   PEERYARD_MATRIX_JAR=<weak-blocks jar> bash rig/rig.sh rig/examples/matrix-tx.json rig/examples/matrix-tx.sh
# PASS = every payment is confirmed in an ordering block on both nodes, at least one payment was seen inside an
# input block on A and on B (so input-block transactions are produced and relayed), and A and B agree by header id,
# state root and input chain at the end. Per-payment latencies are reported, not judged.
N=${MATRIX_TX_N:-5}; AMT=${MATRIX_TX_NANOERG:-100000000}; WAIT=${MATRIX_TX_WAIT_S:-180}; fail=0
in_ordering(){ local hid; hid=$(header_at "$1" "$2"); [ -n "$hid" ] && rest "$1" "/blocks/$hid" | jq -e --arg t "$3" '[.blockTransactions.transactions[].id] | index($t) != null' >/dev/null 2>&1; }
# where_in_input <node> <txid>: the id of the input block in <node>'s best input chain that holds <txid>, or nothing
where_in_input(){ local ib; for ib in $(input_chain_ids "$1"); do input_block_txids "$1" "$ib" | grep -qx "$2" && { echo "$ib"; return; }; done; }
echo "[matrix-tx] A=$(rest A /info | jq -r .appVersion) B=$(rest B /info | jq -r .appVersion); waiting for A's reward to mature"
wait_balance A $((AMT * N + 200000000)) 600 >/dev/null || { echo "[matrix-tx] FAIL: A never had a spendable balance"; rig_verdict=FAIL; return; }
declare -A TIN_A TIN_B TORD IB; seen_in_a=0; seen_in_b=0
for i in $(seq 1 "$N"); do
  id=$(pay A B "$AMT"); [[ "$id" =~ ^[0-9a-f]{64}$ ]] || { echo "  payment $i rejected: $id"; fail=1; continue; }
  t0=$SECONDS; end=$((SECONDS + WAIT))
  while [ $SECONDS -lt $end ]; do
    if [ -z "${TIN_A[$id]:-}" ]; then ib=$(where_in_input A "$id"); [ -n "$ib" ] && { TIN_A[$id]=$((SECONDS - t0)); IB[$id]=$ib; }; fi
    # the miner may not list transactions for its own input blocks: look the payment up on B's copy of A's chain too
    if [ -z "${IB[$id]:-}" ]; then for ib in $(input_chain_ids A); do input_block_txids B "$ib" | grep -qx "$id" && { IB[$id]=$ib; break; }; done; fi
    if [ -n "${IB[$id]:-}" ] && [ -z "${TIN_B[$id]:-}" ] && input_block_txids B "${IB[$id]}" | grep -qx "$id"; then TIN_B[$id]=$((SECONDS - t0)); fi
    ih=$(wallet B "/wallet/transactionById?id=$id" | jq -r '.inclusionHeight // empty' 2>/dev/null)
    if [ -n "$ih" ] && in_ordering A "$ih" "$id"; then TORD[$id]=$((SECONDS - t0)); break; fi
    # every 5 s: how many of A's current input blocks each node can list transactions for, and which (diagnostic)
    if [ $(( (SECONDS - t0) % 5 )) -eq 0 ]; then ibs=$(input_chain_ids A); la=0; lb=0; txs=""
      for ib in $ibs; do ta=$(input_block_txids A "$ib"); tb=$(input_block_txids B "$ib"); [ -n "$ta" ] && la=$((la + 1)); [ -n "$tb" ] && lb=$((lb + 1)); txs+="$(printf '%s\n%s\n' "$ta" "$tb" | sort -u | grep . | cut -c1-8 | tr '\n' ',')"; done
      echo "    t+$((SECONDS - t0))s A input chain: $(wc -w <<< "$ibs") blocks; transaction lists on A: $la, on B: $lb; transactions: [${txs%,}]"; fi
    sleep 1
  done
  [ -n "${TIN_A[$id]:-}" ] && seen_in_a=$((seen_in_a + 1)); [ -n "${TIN_B[$id]:-}" ] && seen_in_b=$((seen_in_b + 1))
  echo "  payment $i ${id:0:12}: in an input block on A after ${TIN_A[$id]:--} s, on B after ${TIN_B[$id]:--} s; confirmed in an ordering block after ${TORD[$id]:-not within ${WAIT}} s"
  [ -n "${TORD[$id]:-}" ] || fail=1
done
sc=$(same_chain A B); ic=$(same_input_chain_stable A B)
stop_mining A >/dev/null
st=NOHEIGHT; for _ in $(seq 1 30); do st=$(same_state A B); case "$st" in SAME@*|DIFF@*) break ;; esac; sleep 2; done
echo "[matrix-tx] payments seen in an input block: A=$seen_in_a B=$seen_in_b of $N; same_chain=${sc%%:*} input_chain=$ic same_state=${st%%:*}"
[ "$seen_in_a" -ge 1 ] && [ "$seen_in_b" -ge 1 ] || fail=1
case "$ic" in SAME@*|PREFIX@*) ;; *) fail=1 ;; esac
case "$st" in SAME@*) ;; *) fail=1 ;; esac
if [ $fail = 0 ]; then rig_verdict=PASS; else rig_verdict=FAIL; fi
echo "[matrix-tx] === MATRIX-TX: $rig_verdict ==="; echo "MATRIX-TX-DONE"
