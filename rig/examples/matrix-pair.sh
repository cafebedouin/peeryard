# matrix-pair: two nodes built from ergo's `weak-blocks` line (sub-blocks: input blocks between ordering
# blocks), alone on one link. A mines, B follows. Chain: the `matrix` preset (the jar's own settings, reward
# delay 10) with the ordering-block interval raised to 20 s. The reason: an input block is a solution whose PoW
# hit lies between the ordering target and 64 times it (parameter 9, "sub-blocks per block", is 64 from genesis
# on a devnet), so at difficulty 1 every solution is an ordering block and no input block can exist. devnet's
# own 100 ms interval pins the difficulty at the floor (the internal miner tries 1000 nonces per poll, so it
# cannot go faster than one block per poll and the retarget drives difficulty down); a 20 s interval makes the
# retarget raise it into the tens of thousands, where most polls yield an input block and few an ordering block.
# Every MATRIX_SAMPLE_S seconds the hook records, on both nodes, the ordering-block height (/info fullHeight),
# the difficulty, the best input block (/blocks/bestInputBlock) and the length of the best input-block chain
# since the last ordering block (/blocks/bestInputChain), and counts the distinct input-block ids each node has
# reported. Those routes are the sub-block surface a mainline 6.0.6 jar does not have; the hook reads them with
# plain `rest` so an oracle can be promoted into rig.sh once the branch's API settles.
#   PEERYARD_MATRIX_JAR=<jar built from weak-blocks> bash rig/rig.sh rig/examples/matrix-pair.json rig/examples/matrix-pair.sh
#   PEERYARD_DURATION seconds to observe (default 360); MATRIX_SAMPLE_S sampling period (default 20)
# PASS = ordering blocks advanced (A at height >= 20), at least one input block was reported by A AND by B
# (so input blocks are produced and relayed), the two nodes agree by header id and by state root at the end
# (same_state SAME@h, sampled for up to 120 s until the heights are equal; LAG@ "same-chain" or "fork" at the end fails),
# and the peer sets match the topology. The cadence (input blocks seen per ordering block) is reported, not judged.
DUR=${PEERYARD_DURATION:-360}; SAMPLE=${MATRIX_SAMPLE_S:-20}
declare -A SEEN_A SEEN_B; na=0; nb=0   # distinct input-block ids seen (counters: an empty array is "unbound" under set -u)
va=$(rest A /info | jq -r '.appVersion // "null"'); vb=$(rest B /info | jq -r '.appVersion // "null"')
echo "[matrix-pair] A appVersion=$va B appVersion=$vb; subblocksPerBlock (A /info parameters): $(rest A /info | jq -c '.parameters.subblocksPerBlock // "absent"'); duration ${DUR}s, sample every ${SAMPLE}s"
echo "[matrix-pair] A /blocks/bestInputBlock at start (raw): $(rest A /blocks/bestInputBlock | head -c 200)"
echo "[matrix-pair] A /blocks/bestInputChain at start (raw): $(rest A /blocks/bestInputChain | head -c 200)"
t0=$SECONDS; h0=$(full_height A); orph=0
while [ $((SECONDS - t0)) -lt "$DUR" ]; do
  sleep "$SAMPLE"
  ia=$(rest A /info); ib=$(rest B /info)
  ha=$(jq -r '.fullHeight // 0' <<< "$ia"); hb=$(jq -r '.fullHeight // 0' <<< "$ib")
  bia=$(rest A /blocks/bestInputBlock); bib=$(rest B /blocks/bestInputBlock)
  ida=$(jq -r '.bestInputBlock // ""' <<< "$bia"); idb=$(jq -r '.bestInputBlock // ""' <<< "$bib")
  ca=$(rest A /blocks/bestInputChain | jq -r '.bestInputBlocks | length' 2>/dev/null); cb=$(rest B /blocks/bestInputChain | jq -r '.bestInputBlocks | length' 2>/dev/null)
  seen_a(){ [ -n "$1" ] && [ -z "${SEEN_A[$1]:-}" ] && { SEEN_A[$1]=1; na=$((na + 1)); }; return 0; }
  seen_b(){ [ -n "$1" ] && [ -z "${SEEN_B[$1]:-}" ] && { SEEN_B[$1]=1; nb=$((nb + 1)); }; return 0; }
  seen_a "$ida"; seen_b "$idb"
  # every id in the current best input chain counts as seen too (a chain longer than one per sample)
  for id in $(rest A /blocks/bestInputChain | jq -r '.bestInputBlocks[]? // empty' 2>/dev/null); do seen_a "$id"; done
  for id in $(rest B /blocks/bestInputChain | jq -r '.bestInputBlocks[]? // empty' 2>/dev/null); do seen_b "$id"; done
  echo "  t+$((SECONDS - t0))s A.h=$ha B.h=$hb difficulty=$(jq -r '.difficulty // "?"' <<< "$ia") A.bestInput=${ida:0:12} chain=${ca:-?} B.bestInput=${idb:0:12} chain=${cb:-?} seen A=$na B=$nb same_chain=$(same_chain A B | cut -c1-14) same_state=$(same_state A B | cut -d: -f1)"
done
hf=$(full_height A); adv=$((hf - h0)); orph=$(orphans_between A $((h0 + 1)) "$hf")
sc=$(same_chain A B); st=$(same_state A B)
# settle: the observation is over, so pause A (B may lag it by a block), then sample same_state until equal heights or 120 s
stop_mining A >/dev/null
end=$((SECONDS + 120)); while [ $SECONDS -lt $end ]; do st=$(same_state A B); case "$st" in SAME@*|DIFF@*) break ;; esac; sleep 2; done
cad=$(awk -v i="$na" -v o="$adv" 'BEGIN { printf "%.2f", (o > 0 ? i / o : 0) }')
echo "[matrix-pair] ordering blocks: $h0 -> $hf (+$adv, orphans $orph); distinct input blocks reported: A=$na B=$nb (about $cad per ordering block on A); same_chain=${sc%%:*}; same_state=${st%%:*}"
echo "[matrix-pair] peers vs topology:"; check_topology_wait && topo=ok || topo=mismatch
res=FAIL
# the docs promise the same state root: only SAME@h passes (LAG@.. same-chain after the settle window, a fork, or DIFF do not)
case "$st" in SAME@*) st_ok=yes ;; *) st_ok=no ;; esac
if [ "$hf" -ge 20 ] && [ "$na" -ge 1 ] && [ "$nb" -ge 1 ] && [ "${sc%%@*}" = SAME ] && [ "$st_ok" = yes ] && [ "$topo" = ok ]; then res=PASS; fi
echo "[matrix-pair] === MATRIX-PAIR: $res (A=$va B=$vb h=$hf inputA=$na inputB=$nb ${sc%%:*} ${st%%:*} topology=$topo) ==="; rig_verdict=$res
echo "MATRIX-PAIR-DONE"
