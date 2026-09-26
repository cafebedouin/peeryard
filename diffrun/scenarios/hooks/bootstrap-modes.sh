# shellcheck shell=bash
# bootstrap-modes: nodes in other state modes sync the same chain and agree on the state root. A mines with a
# full UTXO state; B runs in digest mode (no UTXO set, verifies blocks against their AD proofs); C prunes full
# blocks (blocksToKeep 20). State-root agreement is checked at a settled, equal height: A mines a while, then
# mining stops, B and C catch up to A's exact final height, and only then are the state roots compared (under a
# live miner same_state reports LAG@ because followers trail by a block, which is not a fault but is not proof of
# agreement either). PASS = B and C reach A's final height on the same header ids and the same state root, and C's
# pruning is visible: an old full block (height 5) is served by the full node A but not by the pruned node C,
# while C still holds its header. Env: PEERYARD_DURATION (mining seconds before the settle, default 120).
MINE_S=${PEERYARD_DURATION:-120}
# full_height reads 0 for a few seconds after a (re)launch while the node reloads its chain, so read a height
# after a mining stop only through wait_h.
wait_h(){ local n="$1" min="$2" end=$((SECONDS + ${3:-90})); while [ $SECONDS -lt $end ]; do [ "$(full_height "$n")" -ge "$min" ] 2>/dev/null && { full_height "$n"; return 0; }; sleep 2; done; full_height "$n"; return 1; }
echo "[modes] A: $(grep -h stateType "$SCRATCH"/conf_A.conf | tail -1)  B: $(grep -h stateType "$SCRATCH"/conf_B.conf | tail -1)  C: $(grep -h blocksToKeep "$SCRATCH"/conf_C.conf | tail -1)"

# 1) mine for a while; require B and C to be following A's chain (lag-tolerant) before the settle
end=$((SECONDS + MINE_S)); follow=no
while [ $SECONDS -lt $end ]; do
  a=$(full_height A); b=$(full_height B); c=$(full_height C)
  echo "  mining: A=$a B=$b C=$c  same_chain(A,B)=$(same_chain A B | cut -c1-12) same_chain(A,C)=$(same_chain A C | cut -c1-12)"
  if [ "${a:-0}" -ge 40 ] && [ "$(same_chain A B | cut -c1-4)" = SAME ] && [ "$(same_chain A C | cut -c1-4)" = SAME ]; then follow=yes; fi
  sleep 6
done
[ $follow = yes ] || echo "[modes] WARN: B and/or C were not seen following A's chain during mining"

# 2) stop the miner and let B and C reach A's exact final height, so the state-root comparison is at equal height
ah=$(full_height A)            # capture before the relaunch resets it to 0
stop_mining A
ah=$(wait_h A "$ah")
echo "[modes] mining stopped at A=$ah; waiting for B and C to settle at $ah"
end=$((SECONDS + 120)); settled=no
while [ $SECONDS -lt $end ]; do
  b=$(full_height B); c=$(full_height C)
  [ "${b:-0}" -ge "$ah" ] && [ "${c:-0}" -ge "$ah" ] && { settled=yes; break; }
  sleep 3
done
sb=$(same_state A B); sc=$(same_state A C)
echo "[modes] settled=$settled  A=$ah B=$(full_height B) C=$(full_height C)  same_state(A,B)=$sb same_state(A,C)=$sc"

# 3) pruning visible on C: the old full block at height 5 is served by the full node A but not by the pruned C,
# while C keeps its header. A served full block always carries >= 1 (coinbase) transaction, so a count < 1 from C
# means the block sections are gone.
hdr5=$(header_at A 5); a_block=$(rest A "/blocks/$hdr5" | jq -r '.blockTransactions.transactions | length' 2>/dev/null)
c_hdr5=$(header_at C 5); c_block=$(rest C "/blocks/$c_hdr5" | jq -r '.blockTransactions.transactions | length' 2>/dev/null)
echo "[modes] block 5 header on C: $([ -n "$c_hdr5" ] && echo yes || echo no); full-block transactions served: A(full)=${a_block:-none} C(pruned)=${c_block:-none}"
pruned=no; [ -n "$c_hdr5" ] && [ "${a_block:-0}" -ge 1 ] && [ "${c_block:-0}" -lt 1 ] && pruned=yes

state_ok=no; { [ "${sb%%@*}" = SAME ] && [ "${sc%%@*}" = SAME ]; } && state_ok=yes
echo "[modes] settled=$settled state_agree=$state_ok pruned_visible=$pruned"
if [ $settled = yes ] && [ $state_ok = yes ] && [ $pruned = yes ]; then rig_verdict=PASS; else rig_verdict=FAIL; fi
# diffrun contract (diffrun/README.md): one RESULT_JSON line with the envelope; metrics as in scenarios/bootstrap-modes.json
b2j(){ [ "$1" = yes ] && echo true || echo false; }
va=$(rest A /info | jq -r '.appVersion // "null"'); vb=$(rest B /info | jq -r '.appVersion // "null"'); vc=$(rest C /info | jq -r '.appVersion // "null"')
unr=0; for n in A B C; do [ "$(rest $n /info | jq -r '.appVersion // "null"')" = null ] && unr=$((unr + 1)); done
echo "RESULT_JSON $(jq -cn --arg A "$va" --arg B "$vb" --arg C "$vc" --argjson s "$(b2j $settled)" --argjson g "$(b2j $state_ok)" --argjson p "$(b2j $pruned)" --argjson h "${ah:-0}" --argjson u "$unr" --arg jv "$(${PEERYARD_JAVA:-java} -version 2>&1 | head -1)" \
  '{schema_version:1,scenario:"bootstrap-modes",runtime:{java:$jv},versions:{A:$A,B:$B,C:$C},metrics:{settled:$s,state_agree:$g,pruned_visible:$p,height:$h,unresponsive_after:$u}}')"
echo "[modes] === BOOTSTRAP-MODES: $rig_verdict ==="; echo "MODES-DONE"
