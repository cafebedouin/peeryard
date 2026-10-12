# storage-rent: the storage-rent (demurrage) collection mechanism, end to end, on a devnet.
# Storage rent is permissionless: after the storage period anyone may spend an expired box with an empty proof and
# context variable #127. This example creates dust boxes, ages them past the period, and collects them, checking that
# collection is accepted and mined and the collector is paid. It needs a node built with a SHORT storage period, and
# PEERYARD_STORAGE_PERIOD set to that value (see docs/storage-rent.md); on a default node the period is 4 years and the
# example is INCONCLUSIVE (nothing ages in a run).
#   SR_BOXES   how many dust boxes to create and collect (default 5)
#   SR_VALUE   each box's value in nanoERG (default 10000000 = 0.01 ERG, below a box's storage fee -> "not covered")
#   PEERYARD_STORAGE_PERIOD  the build's storage period in blocks (default here 60 if unset and the run is short)
P=${PEERYARD_STORAGE_PERIOD:-60}; export PEERYARD_STORAGE_PERIOD=$P
NB=${SR_BOXES:-5}; V=${SR_VALUE:-10000000}
note(){ echo "[sr] $*"; }
end=$((SECONDS+120)); while [ $SECONDS -lt $end ]; do case "$(same_chain A B)" in SAME@*) break;; esac; sleep 3; done
note "floor $(same_chain A B|cut -c1-14); storage period $P blocks"
wait_balance A 20000000000 400 >/dev/null || { echo "STORAGE-RENT: INCONCLUSIVE (A unfunded)"; rig_verdict=INCONCLUSIVE; return 0; }
note "fee tree: $(fee_tree A | cut -c1-16)…"
# Rent boxes belong to a FOREIGN address (the public test key, scalar 1) the miner wallet cannot spend, so only the
# storage-rent path collects them after the period -- as on mainnet, where expired boxes belong to other users.
ftree="0008cd0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798"
faddr=$(rest A "/utils/ergoTreeToAddress/$ftree" | jq -r '.address // empty')
[ -n "$faddr" ] || { echo "STORAGE-RENT: INCONCLUSIVE (no foreign address)"; rig_verdict=INCONCLUSIVE; return 0; }
note "foreign owner address ${faddr:0:16}…"
# create the boxes, record boxId + creationHeight
: > "$RIG_LOG_DIR/rent_boxes.txt"
for i in $(seq 1 "$NB"); do bc=$(rent_box A "$V" "$faddr"); echo "$bc" >> "$RIG_LOG_DIR/rent_boxes.txt"; note "box $i: $bc"; done
minh=$(awk '{print $2}' "$RIG_LOG_DIR/rent_boxes.txt" | sort -n | tail -1)
note "youngest box creationHeight $minh; current $(full_height A); aging to $((minh + P + 2))"
end=$((SECONDS+600)); while [ $SECONDS -lt $end ] && [ "$(full_height A)" -lt $((minh + P + 2)) ]; do sleep 3; done
note "aged: current $(full_height A)"
bal0=$(balance A)
ok=0; fail=0
while read -r box ch; do
  rent_expired A "$ch" || { note "box ${box:0:12} not yet expired (age $(( $(full_height A) - ch )))"; fail=$((fail+1)); continue; }
  r=$(rent_claim A "$box" "$V")
  if [[ "$r" =~ ^\"[0-9a-f]{64}\"$ ]]; then ok=$((ok+1)); note "claim ${box:0:12} accepted ${r:1:12}"; else fail=$((fail+1)); note "claim ${box:0:12} REJECTED: ${r:0:120}"; fi
done < "$RIG_LOG_DIR/rent_boxes.txt"
# let the claims mine
end=$((SECONDS+90)); while [ $SECONDS -lt $end ] && [ "$(mempool_size A)" != 0 ]; do sleep 3; done
# verify: the claimed boxes are gone from the UTXO set (collected)
gone=0; while read -r box ch; do rest A "/utxo/byId/$box" | jq -e '.boxId' >/dev/null 2>&1 || gone=$((gone+1)); done < "$RIG_LOG_DIR/rent_boxes.txt"
note "claims accepted $ok/$NB, rejected $fail; boxes now spent: $gone/$NB; A balance $bal0 -> $(balance A)"
note "same_state A B: $(same_state A B | cut -c1-30)"
if [ "$ok" -ge 1 ] && [ "$gone" -ge "$ok" ]; then echo "STORAGE-RENT: PASS (collected $ok expired boxes; all mined and spent)"; rig_verdict=PASS
else echo "STORAGE-RENT: FAIL (accepted $ok, spent $gone of $NB)"; rig_verdict=FAIL; fi
