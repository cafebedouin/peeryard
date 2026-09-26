# txchain: a chain of self-payments in one node's mempool (the ChainGenerator self-payment pattern, driven
# through the wallet). A mines at a slow poll (6 s blocks) so that a burst of payments piles up between blocks
# rather than confirming one per block; there is deliberately NO mining restart after the burst, because a
# relaunch would wipe the in-memory mempool (the chain under test) and look like confirmation. A pays its OWN
# address N times in a burst; because the wallet spends unconfirmed change, each payment spends the previous
# one's output, so the mempool holds a dependency chain. Reported: how many were accepted, whether the pool
# listing kept every parent ahead of its child, and how many confirmed as the slow miner drains the pool.
# PASS = at least 90% accepted, the pool listing is in dependency order, and the pool fully drains (every
# accepted payment confirms) while the chain advances. Env: TXCHAIN_N (default 12), TXCHAIN_NANOERG (0.1 ERG).
N=${TXCHAIN_N:-12}; AMT=${TXCHAIN_NANOERG:-100000000}
echo "[txchain] chain: $(grep -h -E 'blockInterval|minerRewardDelay' "$SCRATCH"/conf_A.conf | tr '\n' ' ')"
echo "[txchain] A address $(address A)"
need=$((AMT + 100000000))   # one matured input seeds the whole chain; a margin for per-tx fees
if bal=$(wait_balance A "$need" 300); then echo "[txchain] A balance $bal nanoERG at height $(full_height A)"
else echo "[txchain] FAIL: A never matured $need nanoERG (balance $bal)"; rig_verdict=FAIL; fi

if [[ "${rig_verdict:-}" != FAIL ]]; then
  h0=$(full_height A); echo "[txchain] sending $N self-payments in a burst from height $h0 (6 s blocks, mining left on)"
  mapfile -t ids < <(txchain A "$N" "$AMT")
  accepted=(); for id in "${ids[@]}"; do
    if [[ "$id" =~ ^[0-9a-f]{64}$ ]]; then accepted+=("$id"); else echo "  rejected: $id"; fi
  done
  acc=${#accepted[@]}; echo "[txchain] accepted $acc/$N self-payments"

  sleep 2
  poolj=$(rest A "/transactions/unconfirmed?limit=10000")
  mapfile -t pool < <(jq -r '.[]?.id // empty' <<< "$poolj" 2>/dev/null)
  echo "[txchain] mempool holds ${#pool[@]} unconfirmed right after the burst"

  # Dependency order: the accepted ids were emitted parent-first. Keep the accepted ids that are still in the
  # pool, in the pool's listed order, and check the listing keeps every parent ahead of its child (no child's
  # send-rank before its parent's). Some payments may already have confirmed under the slow miner; those simply
  # are not in the pool and do not affect the order check.
  declare -A rank; for i in "${!accepted[@]}"; do rank["${accepted[$i]}"]=$i; done
  pool_seq=""; for id in "${pool[@]}"; do [[ -n "${rank[$id]:-}" ]] && pool_seq="$pool_seq ${rank[$id]}"; done
  ordered=yes; prev=-1
  for r in $pool_seq; do [[ "$r" -gt "$prev" ]] || ordered=no; prev="$r"; done
  in_pool=$(wc -w <<< "$pool_seq")
  echo "[txchain] of $acc accepted, $in_pool are still in the pool; parent-before-child in the listing: $ordered"
  # the premise: a dependency chain in the pool. Consecutive accepted payments both still pooled must be chained (the
  # child spends one of the parent's outputs); with fewer than two pooled there is no order to check.
  pairs=0; chained=0
  for ((i = 1; i < acc; i++)); do
    par=${accepted[$((i - 1))]}; ch=${accepted[$i]}
    jq -e --arg p "$par" --arg c "$ch" 'any(.[]; .id == $p) and any(.[]; .id == $c)' <<< "$poolj" >/dev/null 2>&1 || continue
    pairs=$((pairs + 1))
    jq -e --arg p "$par" --arg c "$ch" '([.[] | select(.id == $p) | .outputs[].boxId]) as $o
      | any(.[] | select(.id == $c) | .inputs[].boxId; . as $b | $o | index($b))' <<< "$poolj" >/dev/null 2>&1 && chained=$((chained + 1))
  done
  echo "[txchain] consecutive pooled pairs: $pairs, of them chained (child spends the parent's output): $chained"

  echo "[txchain] draining: the slow miner confirms the dependency chain block by block"
  end=$((SECONDS + 240)); left=$acc
  while [[ $SECONDS -lt $end ]]; do
    left=$(mempool_size A); [[ "${left:-1}" -eq 0 ]] && break; sleep 3
  done
  h1=$(full_height A); confirmed=$((acc - ${left:-0}))
  echo "[txchain] after draining: mempool has ${left} left; $confirmed/$acc confirmed; height $h0 -> $h1"

  if [[ "$in_pool" -lt 2 || "$chained" -lt 1 ]]; then
    echo "[txchain] INCONCLUSIVE: no dependency chain in the pool to check (pooled=$in_pool, chained pairs=$chained)"
    rig_verdict=INCONCLUSIVE; rig_cause=NO_CHAIN_IN_POOL
  elif [[ $acc -ge $((N * 9 / 10)) && "$ordered" = yes && "${left:-1}" -eq 0 && "$h1" -gt "$h0" ]]; then rig_verdict=PASS; else rig_verdict=FAIL; fi
fi
echo "[txchain] === TXCHAIN: ${rig_verdict:-FAIL} (accepted=${acc:-0}/$N ordered=${ordered:-?} confirmed=${confirmed:-0}) ==="
echo "TXCHAIN-DONE"
