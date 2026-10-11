# storage-rent-war: competing collectors race for the same expiring boxes (the "mempool war"). M mines; a pool of
# holder boxes ages past the storage period; then several collector bots with different reaction latencies and fee bids
# race to claim them. Reports each bot's wins and collisions. Needs a short-period test build + PEERYARD_STORAGE_PERIOD.
#   SRW_BOXES  holder boxes (default 8)
#   SRW_VALUE  each box value nanoERG (default 10000000)
# Bots (label:node:latency_ms:fee_bid): fast low-bid, slow high-bid, and a mid — tune to taste.
P=${PEERYARD_STORAGE_PERIOD:-60}; export PEERYARD_STORAGE_PERIOD=$P
NB=${SRW_BOXES:-8}; V=${SRW_VALUE:-10000000}
note(){ echo "[srw] $*"; }
end=$((SECONDS+120)); while [ $SECONDS -lt $end ]; do case "$(same_chain M N)" in SAME@*) break;; esac; sleep 3; done
note "floor $(same_chain M N|cut -c1-14); period $P"
wait_balance M 20000000000 400 >/dev/null || { echo "STORAGE-RENT-WAR: INCONCLUSIVE (M unfunded)"; rig_verdict=INCONCLUSIVE; return 0; }
fee_tree M >/dev/null
ftree="0008cd0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798"
faddr=$(rest M "/utils/ergoTreeToAddress/$ftree" | jq -r '.address // empty')
: > "$RIG_LOG_DIR/warboxes.txt"
for i in $(seq 1 "$NB"); do bc=$(rent_box M "$V" "$faddr"); echo "$bc $V" >> "$RIG_LOG_DIR/warboxes.txt"; done
note "created $NB holder boxes; $(wc -l < "$RIG_LOG_DIR/warboxes.txt") recorded"
minh=$(awk '{print $2}' "$RIG_LOG_DIR/warboxes.txt" | sort -n | tail -1)
note "aging to $((minh + P + 2)) (current $(full_height M))"
end=$((SECONDS+600)); while [ $SECONDS -lt $end ] && [ "$(full_height M)" -lt $((minh + P + 2)) ]; do sleep 3; done
note "aged: current $(full_height M); releasing the bots (compete strategy: each bot claims every box once)"
export RENT_BOT_STRATEGY=compete
# three competing collectors, all against M (shared mempool): fast/cheap, mid, slow/rich
rent_bot fast M "$RIG_LOG_DIR/warboxes.txt" 0    0       300
rent_bot mid  M "$RIG_LOG_DIR/warboxes.txt" 200  500000  300
rent_bot slow M "$RIG_LOG_DIR/warboxes.txt" 600  2000000 300
# let them fight and the miner include winners
end=$((SECONDS+120)); while [ $SECONDS -lt $end ] && [ "$(ls "$RIG_LOG_DIR/rent_won" 2>/dev/null | wc -l)" -lt "$NB" ]; do sleep 3; done
rent_bots_stop
sleep 6
tot=0
for b in fast mid slow; do
  a=$(grep -c '"result":"accepted"' "$RIG_LOG_DIR/bot_$b.jsonl" 2>/dev/null); a=${a:-0}
  r=$(grep -c '"result":"rejected"' "$RIG_LOG_DIR/bot_$b.jsonl" 2>/dev/null); r=${r:-0}
  tot=$((tot + a + r)); note "bot $b: submitted $((a + r)) (accepted-at-submit $a, rejected $r; accepted-at-submit includes claims later replaced by a higher fee)"
done
note "total claim submissions $tot for $NB boxes -> war ratio $(awk -v t="$tot" -v n="$NB" 'BEGIN{printf "%.1fx", (n>0?t/n:0)}') (mempool keeps 1/box via double-spend replacement; the surplus is churn)"
won=$(ls "$RIG_LOG_DIR/rent_won" 2>/dev/null | wc -l)
spent=0; while read -r box ch val; do rest M "/utxo/byId/$box" | jq -e '.boxId' >/dev/null 2>&1 || spent=$((spent+1)); done < "$RIG_LOG_DIR/warboxes.txt"
note "boxes won (first-accept) $won/$NB; boxes now spent $spent/$NB; same_state M N $(same_state M N | cut -c1-24)"
if [ "$spent" -ge 1 ] && [ "$won" -ge 1 ]; then echo "STORAGE-RENT-WAR: PASS (contended collection: $spent/$NB boxes collected under competition)"; rig_verdict=PASS
else echo "STORAGE-RENT-WAR: FAIL (won $won, spent $spent of $NB)"; rig_verdict=FAIL; fi
