# mempool-evict: eviction and fee ordering in a small mempool. Both nodes run with mempoolCapacity = 20 and
# mempoolSorting = "bySize" (fee per byte), so a transaction's place in the pool is its fee weight. A mines with
# a 45 s poll (about one block per poll at the devnet's floor difficulty) and a 3-block reward delay, so it is
# never restarted (a restart empties a node's in-memory pool) and there is a window of about 45 s between
# blocks in which the pool can be filled and probed. B holds a separate wallet. A pays B once; right after the
# block that confirms it, A fills its own pool with 20 self-payments whose fees DECREASE from 41 to 2 times the
# minimum fee, so the lowest-weight transaction is the newest leaf of A's chain and evicting it invalidates
# nothing. Then B submits (1) a payment at the minimum fee, whose fee per byte is below every pool transaction,
# which the node must decline ("Transaction pays less than any other in the pool being full",
# ErgoMemPool.acceptIfNoDoubleSpend), and (2) a payment at ten times the minimum, which must be accepted with
# the pool staying at capacity and A's lowest-fee id gone. The next blocks must confirm the remaining 20.
#   PEERYARD_JAR=~/ergo-6.0.6.jar bash rig/rig.sh rig/examples/mempool-evict.json rig/examples/mempool-evict.sh
# PASS = the pool never exceeds 20; the low-fee payment is declined with the node's capacity message; the
# high-fee payment is accepted; the evicted transaction is A's lowest-fee one (it was in the pool after the fill
# and is gone after the high-fee payment, with no block in between); at least 20 non-coinbase transactions
# confirm in the following blocks. INCONCLUSIVE = the probe did not start from a full pool holding A's lowest-fee
# transaction (a self-payment was rejected at submission, or a block landed during the fill or the probe), so an
# absent id could be a rejection or a confirmation rather than an eviction.
CAP=20; F=1000000   # the node's minimal fee (minimalFeeAmount = 1000000 nanoERG)
echo "[evict] A pool: $(grep -h -E 'mempoolCapacity=20|mempoolSorting' "$SCRATCH"/conf_A.conf | tr '\n' ' '); A polls every $(grep -h internalMinerPollingInterval "$SCRATCH"/conf_A.conf)"
echo "[evict] waiting for A's rewards to mature (reward delay 3) and funding B"
wait_balance A 5000000000 400 >/dev/null || { echo "[evict] FAIL: A never had a spendable balance"; rig_verdict=FAIL; return; }
funding=$(pay A B 3000000000); echo "[evict] A -> B 3 ERG: $funding (at height $(full_height A))"
wait_balance B 3000000000 200 >/dev/null || { echo "[evict] FAIL: B's funding never confirmed"; rig_verdict=FAIL; return; }
h_fund=$(full_height A); echo "[evict] funding confirmed at height $h_fund; the next block is due in <= 45 s: filling now"
[ "$(mempool_size A)" = 0 ] || echo "[evict] note: pool not empty at start ($(mempool_size A))"
toA=$(address A); low_id=""
for ((k=1;k<=CAP;k++)); do fee=$(( (CAP + 2 - k) * F ))   # 41F .. 2F
  id=$(wallet A /wallet/transaction/send "{\"requests\":[{\"address\":\"$toA\",\"value\":100000000}],\"fee\":$fee}" | jq -r 'if type == "string" then . else "REJECT:" + (.detail // .reason // tojson) end')
  [ ${#id} = 64 ] || echo "[evict] self-payment $k (fee $fee) rejected at submission: $id"
  [ $k = "$CAP" ] && low_id=$id; sleep 0.2
done
sleep 1; n0=$(mempool_size A); h_probe=$(full_height A)
low_in0=no; [ ${#low_id} = 64 ] && grep -qx "$low_id" <<< "$(mempool_ids A)" && low_in0=yes
echo "[evict] pool after fill: $n0 (capacity $CAP) at height $h_probe; lowest-fee id ${low_id:0:12} (fee $((2 * F))) in pool: $low_in0"
r_low=$(send_fee B A 100000000 "$F"); echo "[evict] B pays with the minimum fee $F (below every pool tx's fee per byte): $r_low"
n1=$(mempool_size A)
r_high=$(send_fee B A 100000000 $((10 * F))); echo "[evict] B pays with fee $((10 * F)): $r_high"
sleep 1; n2=$(mempool_size A); h_after=$(full_height A)
# evicted = it was in the pool after the fill, is gone now, and no block landed in between (a block would remove it too)
gone=no; [ $low_in0 = yes ] && [ "$h_after" = "$h_probe" ] && ! grep -qx "$low_id" <<< "$(mempool_ids A)" && gone=yes
high_in=no; [ ${#r_high} = 64 ] && mempool_ids A | grep -q "^$r_high$" && high_in=yes
low_declined=no; case "$r_low" in *"pays less"*|*"less than any"*|*"being full"*) low_declined=yes ;; esac
echo "[evict] pool sizes: after fill $n0, after the low-fee attempt $n1, after the high-fee one $n2; low-fee declined: $low_declined; A's lowest evicted: $gone; B's high-fee tx in pool: $high_in (height still $(full_height A), funding block $h_fund)"
echo "[evict] waiting for the next blocks to confirm the pool"
end=$((SECONDS + 200)); drained=no; while [ $SECONDS -lt $end ]; do [ "$(mempool_size A)" = 0 ] && [ "$(full_height A)" -gt "$h_fund" ] && { drained=yes; break; }; sleep 3; done
hb=$(full_height A); txs=0; for ((h=h_fund+1; h<=hb; h++)); do c=$(block_txs A $h); txs=$((txs + c - 1)); done
echo "[evict] drained: $drained at height $hb; non-coinbase txs confirmed in blocks $((h_fund + 1))..$hb: $txs; pool now $(mempool_size A)"
res=FAIL
if [ "$n0" -le $CAP ] && [ "$n2" = $CAP ] && [ $low_declined = yes ] && [ $high_in = yes ] && [ $gone = yes ] && [ $drained = yes ] && [ "$txs" -ge 20 ]; then res=PASS
elif [ "$n0" -le $CAP ] && { [ "$n0" != $CAP ] || [ $low_in0 = no ] || [ "$h_after" != "$h_probe" ]; }; then
  res=INCONCLUSIVE; echo "[evict] INCONCLUSIVE: the probe did not start from a full pool holding A's lowest-fee tx with no block during it (fill=$n0/$CAP lowest-in-pool=$low_in0 height $h_probe -> $h_after)"
fi
echo "[evict] === MEMPOOL-EVICT: $res (fill=$n0/$CAP low-fee-declined=$low_declined high-fee-in=$high_in evicted-lowest=$gone drained=$drained confirmed=$txs) ==="; rig_verdict=$res
echo "MEMPOOL-EVICT-DONE"
