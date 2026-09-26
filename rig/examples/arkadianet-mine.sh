# arkadianet-mine: the reverse of arkadianet-follow. B is an arkadianet node with "mining": true, which makes it
# serve block candidates on /mining/* (it has no internal miner); the rig's solver loop (solve_start) submits a
# solution per candidate, valid at the rust-devnet preset's difficulty of 1. A is the JVM reference node
# (PEERYARD_JAR), not mining, dialled by B, and must follow the Rust-mined chain.
#   PEERYARD_JAR=~/ergo-6.0.6.jar PEERYARD_ARKADIANET_BIN=<binary> bash rig/rig.sh rig/examples/arkadianet-mine.json rig/examples/arkadianet-mine.sh
# PASS = B mined at least 10 blocks (its full height rose from 0), A is on B's chain by header id at height >= 10
# with full height equal to header height, the state roots agree at an equal height after the solver stops,
# the peer sets match the topology, and the two appVersions differ.
va=$(rest A /info | jq -r '.appVersion // "null"'); vb=$(rest B /info | jq -r '.appVersion // "null"')
echo "[arkadianet-mine] A (jvm, follower) appVersion=$va  B (arkadianet, mining) appVersion=$vb network=$(rest B /info | jq -r '.network // "?"')"
echo "[arkadianet-mine] B /mining/candidate at start: $(wallet B /mining/candidate | cut -c1-160)"
solve_start B
end=$((SECONDS + 240)); mined=no; sc=""
while [ $SECONDS -lt $end ]; do
  bh=$(full_height B); ai=$(rest A /info); af=$(jq -r '.fullHeight // 0' <<< "$ai"); ah=$(jq -r '.headersHeight // 0' <<< "$ai")
  sc=$(same_chain A B)
  echo "  B.full=$bh  A.full=$af A.hdr=$ah  same_chain=${sc:0:14}  solver: $(tail -1 "$RIG_LOG_DIR/solver_B.log" 2>/dev/null | cut -c1-70)"
  [ "${bh:-0}" -ge 10 ] && case "$sc" in SAME@*) h=${sc#SAME@}; h=${h%%:*}; [ "$af" = "$ah" ] && [ "${h:-0}" -ge 10 ] && { mined=yes; break; } ;; esac
  sleep 5
done
solve_stop B
# settle: with the solver stopped the heights meet, then compare state roots
st=LAG; end=$((SECONDS + 60)); while [ $SECONDS -lt $end ]; do st=$(same_state A B); case "$st" in SAME@*|DIFF@*) break ;; esac; sleep 2; done
acc=$(grep -c -- '-> accepted\|-> {}\|-> "' "$RIG_LOG_DIR/solver_B.log" 2>/dev/null || echo 0)
echo "[arkadianet-mine] solver submissions: $(wc -l < "$RIG_LOG_DIR/solver_B.log" 2>/dev/null || echo 0) (first: $(head -1 "$RIG_LOG_DIR/solver_B.log" 2>/dev/null | cut -c1-100))"
echo "[arkadianet-mine] B mined to $(full_height B); A at $(full_height A); same_chain=${sc%%:*} same_state=${st%%:*}"
echo "[arkadianet-mine] peers vs topology:"; check_topology && topo=ok || topo=mismatch
res=FAIL
if [ $mined = yes ] && [ "$topo" = ok ] && [ "$va" != "$vb" ] && [ "$va" != null ] && [ "$vb" != null ]; then case "$st" in SAME@*) res=PASS ;; esac; fi
echo "[arkadianet-mine] === ARKADIANET-MINE: $res (A=$va B=$vb mined=$mined ${sc%%:*} ${st%%:*} topology=$topo submissions=$acc) ==="; rig_verdict=$res
echo "ARKADIANET-MINE-DONE"
