# matrix-mixed: a node built from ergo's `weak-blocks` line (sub-blocks) next to a release node (PEERYARD_JAR,
# the current line) on one link, chain preset "matrix". Phase 1: A (Matrix) mines, B (release) follows: does the
# release node peer with the Matrix node and follow its ordering blocks by header id and state root? Phase 2:
# A stops mining, B mines: does the Matrix node follow the release node's blocks? Both node logs are then
# searched for lines about the other side (ban / blacklist / peer scoring / invalid modifier), and the
# Matrix node's input-block surface (/blocks/bestInputBlock) is reported for the record.
#   PEERYARD_MATRIX_JAR=<weak-blocks jar> PEERYARD_JAR=~/ergo-6.0.6.jar bash rig/rig.sh rig/examples/matrix-mixed.json rig/examples/matrix-mixed.sh
# PASS = the two appVersions differ, both phases converge (SAME header ids at least 130 blocks past the phase start,
# the follower's full height equals its header height, same state root: same_state SAME@h; a LAG@ reading, whether
# "same-chain" or "fork", is not a same state root; once the chains agree the miner is paused and the state compared at
# equal heights), the peer sets match the topology, and
# neither log has a ban or blacklist line about the other node. Peer-scoring and invalid-modifier counts are reported.
va=$(rest A /info | jq -r '.appVersion // "null"'); vb=$(rest B /info | jq -r '.appVersion // "null"')
echo "[matrix-mixed] A (Matrix) appVersion=$va jar=$(basename "${NODE_JAR[A]}")  B (release) appVersion=$vb jar=$(basename "${NODE_JAR[B]}")"
follow(){ # follow <miner> <follower> <min height>: wait until the follower is on the miner's chain, fully synced, same state
  local m=$1 f=$2 minh=$3 end=$((SECONDS + 420)) sc st info ff fh h ok=no
  while [ $SECONDS -lt $end ]; do
    info=$(rest "$f" /info); ff=$(jq -r '.fullHeight // 0' <<< "$info"); fh=$(jq -r '.headersHeight // 0' <<< "$info")
    sc=$(same_chain "$m" "$f"); st=$(same_state "$m" "$f")
    echo "  $m.full=$(full_height "$m") $f.full=$ff $f.hdr=$fh same_chain=${sc:0:14} same_state=${st%%:*} $m.bestInput=$(rest "$m" /blocks/bestInputBlock | jq -r '.bestInputBlock // ""' 2>/dev/null | cut -c1-12)"
    case "$sc" in SAME@*) h=${sc#SAME@}; h=${h%%:*}
      if [ "$ff" = "$fh" ] && [ "${h:-0}" -ge "$minh" ]; then
        # the state check needs equal heights, which a 1 s miner rarely leaves: pause the miner, then compare
        [ "${MINING_OVR[$m]:-}" = false ] || stop_mining "$m" >/dev/null
        for _ in $(seq 1 30); do st=$(same_state "$m" "$f"); case "$st" in SAME@*|DIFF@*) break ;; esac; sleep 2; done
        case "$st" in SAME@*) ok=yes ;; esac
      fi ;; esac
    [ $ok = yes ] && break; sleep 10
  done
  echo "[matrix-mixed] $m mines, $f follows: converged=$ok ($sc, ${st%%:*})"; [ $ok = yes ]; }
echo "[matrix-mixed] phase 1: A (Matrix) mines, B (release) follows"
follow A B 130 && p1=ok || p1=FAIL
h1=$(full_height A)
echo "[matrix-mixed] phase 2: A stops, B (release) mines, A (Matrix) follows"
[ "${MINING_OVR[A]:-}" = false ] || stop_mining A; start_mining B 1s
follow B A $((h1 + 130)) && p2=ok || p2=FAIL
echo "[matrix-mixed] peers vs topology:"; check_topology_wait && topo=ok || topo=mismatch
# what each log says about the other side (counts; ban/blacklist lines fail the run, the rest is reported)
la="$RIG_LOG_DIR/node_A.log"; lb="$RIG_LOG_DIR/node_B.log"
ban=$(grep -c -iE 'blacklist|banned|banning' "$la" "$lb" | awk -F: '{s+=$2} END {print s+0}')
pen=$(grep -c -iE 'penaliz|penalty|misbehav' "$la" "$lb" | awk -F: '{s+=$2} END {print s+0}')
inv=$(grep -c -iE 'invalid modifier|is invalid|Invalid .* from peer' "$la" "$lb" | awk -F: '{s+=$2} END {print s+0}')
echo "[matrix-mixed] log lines about the other node: ban/blacklist=$ban peer-scoring=$pen invalid-modifier=$inv"
[ "$pen" -gt 0 ] && { echo "[matrix-mixed] peer-scoring lines:"; grep -h -iE 'penaliz|penalty|misbehav' "$la" "$lb" | head -5; }
[ "$inv" -gt 0 ] && { echo "[matrix-mixed] invalid-modifier lines:"; grep -h -iE 'invalid modifier|is invalid|Invalid .* from peer' "$la" "$lb" | head -5; }
res=FAIL
if [ "$va" != "$vb" ] && [ "$va" != null ] && [ "$vb" != null ] && [ $p1 = ok ] && [ $p2 = ok ] && [ $topo = ok ] && [ "$ban" = 0 ]; then res=PASS; fi
echo "[matrix-mixed] === MATRIX-MIXED: $res (A=$va B=$vb phase1=$p1 phase2=$p2 topology=$topo ban=$ban scoring=$pen invalid=$inv) ==="; rig_verdict=$res
echo "MATRIX-MIXED-DONE"
