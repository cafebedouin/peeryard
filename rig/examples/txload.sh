# txload: real transactions on the devnet. A mines into its wallet; once the reward delay has passed (the rig's
# chain default is 10 blocks) it pays B, whose wallet holds different keys (a per-node testMnemonic override,
# the BIP-39 test vector "abandon ... about"), N times. PASS = at least 90% of the payments were accepted, B's
# confirmed balance reaches what was sent, and the blocks mined meanwhile carry at least that many non-coinbase
# transactions (expect about twice as many: each block that includes paid transactions also carries the miner's
# fee-collection transaction). This exercises the mempool, transaction relay, block assembly with transactions,
# and both wallets, which the empty-block scenarios do not.
N=${TXLOAD_N:-20}; AMT=${TXLOAD_NANOERG:-100000000}   # 0.1 ERG each
echo "[txload] chain: $(grep -h -E 'blockInterval|minerRewardDelay' "$SCRATCH"/conf_A.conf | tr '\n' ' ')"
echo "[txload] A address $(address A)"
echo "[txload] B address $(address B)"
[[ "$(address A)" != "$(address B)" ]] || { echo "[txload] FAIL: A and B share an address (the mnemonic override did not apply)"; rig_verdict=FAIL; }
need=$((AMT * N * 2))
if [[ "${rig_verdict:-}" != FAIL ]]; then
  if bal=$(wait_balance A "$need" 300); then echo "[txload] A balance $bal nanoERG at height $(full_height A)"
  else echo "[txload] FAIL: A never reached $need nanoERG spendable (balance $bal at height $(full_height A))"; rig_verdict=FAIL; fi
fi
sent=0; failed=0; bb=0; total=0
if [[ "${rig_verdict:-}" != FAIL ]]; then
  h0=$(full_height A)
  for i in $(seq 1 "$N"); do
    id=$(pay A B "$AMT")
    if [[ "$id" =~ ^[0-9a-f]{64}$ ]]; then sent=$((sent + 1)); else failed=$((failed + 1)); echo "  pay $i rejected: $id"; fi
    sleep 0.5
  done
  echo "[txload] sent $sent/$N payments ($failed rejected) from height $h0"
  if bb=$(wait_balance B $((AMT * sent)) 240); then echo "[txload] B confirmed balance $bb nanoERG (expected >= $((AMT * sent)))"
  else echo "[txload] B confirmed balance only $bb nanoERG (expected >= $((AMT * sent)))"; fi
  h1=$(full_height A)
  for ((h = h0; h <= h1; h++)); do t=$(block_txs A "$h"); total=$((total + t - 1)); done   # minus one coinbase per block
  echo "[txload] non-coinbase transactions in A's blocks $h0..$h1: $total"
  echo "[txload] same_chain(A,B): $(same_chain A B)"
  if [[ "${bb:-0}" -ge $((AMT * sent)) && $sent -ge $((N * 9 / 10)) && $total -ge $sent ]]; then rig_verdict=PASS; else rig_verdict=FAIL; fi
fi
echo "[txload] === TXLOAD: ${rig_verdict:-FAIL} (sent=$sent rejected=$failed B-balance=${bb:-0} txs-in-blocks=$total) ==="
echo "TXLOAD-DONE"
