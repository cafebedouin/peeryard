# upgrade-mixed: a network part-way through an upgrade. B1 and B2 run the baseline jar (PEERYARD_JAR_B), C1 and C2
# the candidate (PEERYARD_JAR). Links B1-C1 (100 ms), B1-C2 and C1-B2, so each follower reaches the network only
# through a node of the other version. Three phases, each ending with every node on the phase's chain:
#   1. baseline mines   B1 mines; C1 and C2 follow it directly, B2 through C1 (the candidate relays baseline
#                       blocks). B1 pays C2 (a baseline-built transaction confirmed into a candidate wallet).
#   2. candidate mines  B1 stops, C1 mines; B1 and B2 follow it directly, C2 through B1. C1 pays B2.
#   3. both mine        B1 and C1 mine at once for UPG_BOTH_S seconds over the 100 ms link, so competing blocks fork
#                       and resolve across versions; then C1 stops, B1 settles with C2 and pauses.
# The miners have different keys, so the final chain says who mined each block of phase 3.
#   PEERYARD_JAR_B=<baseline.jar> PEERYARD_JAR=<candidate.jar> bash rig/rig.sh rig/examples/upgrade-mixed.json rig/examples/upgrade-mixed.sh
# PASS = the four nodes report two distinct versions, as placed; every phase converged (each node on the leader's
# chain, within UPG_LAG blocks of its height, no fork reading); both payments confirmed into the receiving wallet;
# at the end all four on one state root at one height, with blocks of both miners in phase 3 on that chain; and no
# ban or blacklist line in any node log. Penalty lines are counted and printed, not judged.
#   UPG_BLOCKS (25 per single-miner phase), UPG_BOTH_S (120), UPG_LAG (4), UPG_NANOERG (100000000)
NB=${UPG_BLOCKS:-25}; BOTH=${UPG_BOTH_S:-120}; LAG=${UPG_LAG:-4}; AMT=${UPG_NANOERG:-100000000}
ALL=(B1 C1 C2 B2)
note(){ echo "[upgrade-mixed] $*"; }
ver(){ rest "$1" /info | jq -r '.appVersion // "null"'; }
pk_at(){ local id; id=$(header_at "$1" "$2"); [[ -n "$id" ]] && rest "$1" "/blocks/$id/header" | jq -r '.powSolutions.pk // empty'; }
upg_end(){ echo "[upgrade-mixed] === UPGRADE-MIXED: $1 ($2) ==="; rig_verdict=$1; }
# converge <leader> <label> <node>...: within 180 s, every node on the leader's chain (same_chain SAME) and within LAG
# blocks of its height; a DIFF or a LAG@.. fork reading keeps the poll going and counts against the step at its end
converge(){ local l=$1 label=$2; shift 2; local end=$((SECONDS + 180)) ok=no n sc st lh nh line
  while [[ $SECONDS -lt $end ]]; do ok=yes; lh=$(full_height "$l")
    for n in "$@"; do sc=$(same_chain "$l" "$n"); st=$(same_state "$l" "$n"); nh=$(full_height "$n")
      case "$sc" in SAME@*) ;; *) ok=no ;; esac
      case "$st" in DIFF@*|LAG@*" fork") ok=no ;; esac
      [[ $((lh - ${nh:-0})) -le $LAG ]] || ok=no
    done
    [[ $ok == yes ]] && break; sleep 3
  done
  line=""; for n in "$@"; do line+="$n:$(same_chain "$l" "$n" | cut -c1-7)@$(full_height "$n") "; done
  note "$label: converged=$ok  $l=$(full_height "$l")  $line"; [[ $ok == yes ]]; }
mine_to(){ local m=$1 t=$2 end=$((SECONDS + 300)); while [[ $SECONDS -lt $end && "$(full_height "$m")" -lt "$t" ]]; do sleep 3; done; [[ "$(full_height "$m")" -ge "$t" ]]; }

upgrade_mixed(){
  local cand base n v vB vC fails="" h1 h2 h3 id i pB pC nB=0 nC=0 nX=0 h p st ok bans pens
  cand="$(readlink -f "${PEERYARD_JAR:-}")"; base="$(readlink -f "${PEERYARD_JAR_B:-}")"
  [[ -n "${PEERYARD_JAR_B:-}" && -f "$base" && -f "$cand" ]] || { upg_end INCONCLUSIVE "needs PEERYARD_JAR_B (baseline) and PEERYARD_JAR (candidate)"; return; }
  [[ "$(sha256sum "$cand" | cut -d' ' -f1)" != "$(sha256sum "$base" | cut -d' ' -f1)" ]] || { upg_end INCONCLUSIVE "the baseline and candidate jars are the same file"; return; }
  vB=$(ver B1); vC=$(ver C1)
  for n in "${ALL[@]}"; do v=$(ver "$n"); note "$n appVersion $v jar $(basename "${NODE_JAR[$n]}")"
    case "$n" in B*) [[ "$v" == "$vB" ]] || fails+=" placement($n=$v)" ;; C*) [[ "$v" == "$vC" ]] || fails+=" placement($n=$v)" ;; esac; done
  [[ "$vB" != null && "$vC" != null && "$vB" != "$vC" ]] || { upg_end INCONCLUSIVE "the nodes do not report two distinct versions (baseline $vB, candidate $vC)"; return; }
  check_topology_wait 90 | sed 's/^/  /'

  # 1. the baseline mines: the candidate follows it, and relays it to the other baseline node
  mine_to B1 "$NB" || { upg_end INCONCLUSIVE "B1 did not reach height $NB"; return; }
  converge B1 "phase 1 (baseline B1 mines)" C1 C2 B2 || fails+=" phase1"
  wait_balance B1 $((AMT * 8)) 240 > /dev/null || { upg_end INCONCLUSIVE "B1 never had $((AMT * 8)) nanoERG to pay with"; return; }
  for i in 1 2; do id=$(pay B1 C2 "$AMT"); note "B1 -> C2 payment $i: ${id:0:64}"; sleep 1; done
  if wait_balance C2 $((AMT * 2)) 240 > /dev/null; then note "C2 (candidate) confirmed $(balance C2) from B1 (baseline)"
  else note "C2 balance $(balance C2), expected >= $((AMT * 2))"; fails+=" pay-baseline-to-candidate"; fi
  h1=$(full_height B1); pB=$(pk_at B1 "$h1")

  # 2. the candidate mines: the baseline follows it, and relays it to the other candidate node
  stop_mining B1 > /dev/null; start_mining C1 2s > /dev/null
  mine_to C1 $((h1 + NB)) || { upg_end INCONCLUSIVE "C1 did not reach height $((h1 + NB))"; return; }
  converge C1 "phase 2 (candidate C1 mines)" B1 B2 C2 || fails+=" phase2"
  if wait_balance C1 $((AMT * 8)) 300 > /dev/null; then
    for i in 1 2; do id=$(pay C1 B2 "$AMT"); note "C1 -> B2 payment $i: ${id:0:64}"; sleep 1; done
    if wait_balance B2 $((AMT * 2)) 240 > /dev/null; then note "B2 (baseline) confirmed $(balance B2) from C1 (candidate)"
    else note "B2 balance $(balance B2), expected >= $((AMT * 2))"; fails+=" pay-candidate-to-baseline"; fi
  else note "C1's rewards did not mature to $((AMT * 8)) nanoERG"; fails+=" pay-candidate-to-baseline(no funds)"; fi
  h2=$(full_height C1); pC=$(pk_at C1 "$h2")
  [[ -n "$pB" && -n "$pC" && "$pB" != "$pC" ]] || { upg_end INCONCLUSIVE "the two miners' keys could not be told apart (B1 ${pB:0:12}, C1 ${pC:0:12})"; return; }

  # 3. both mine at once; then C1 stops and B1 settles with C2 (two hops from C1) and pauses
  start_mining B1 2s > /dev/null
  note "phase 3: B1 and C1 mine together for ${BOTH}s from height $h2"
  sleep "$BOTH"
  stop_mining C1 > /dev/null
  settle_follow B1 C2 $((h2 + 5)) 180 || note "settle B1-C2: ${SETTLE_STATE:0:40}"
  end=$((SECONDS + 120)); ok=no
  while [[ $SECONDS -lt $end ]]; do ok=yes; for n in C1 C2 B2; do case "$(same_state B1 "$n")" in SAME@*) ;; *) ok=no ;; esac; done
    [[ $ok == yes ]] && break; sleep 3; done
  st=""; for n in C1 C2 B2; do st+="$n:$(same_state B1 "$n" | cut -c1-14) "; done
  note "end: B1=$(full_height B1) $st"
  [[ $ok == yes ]] || fails+=" final-state"
  h3=$(full_height B1)
  for ((h = h2 + 1; h <= h3; h++)); do p=$(pk_at B1 "$h"); if [[ "$p" == "$pB" ]]; then nB=$((nB + 1)); elif [[ "$p" == "$pC" ]]; then nC=$((nC + 1)); else nX=$((nX + 1)); fi; done
  note "phase 3 blocks on the final chain ($((h2 + 1))..$h3): baseline miner $nB, candidate miner $nC, unread $nX"
  [[ $nB -ge 1 && $nC -ge 1 ]] || fails+=" phase3-both-miners(B=$nB,C=$nC)"
  bans=$(cat "$RIG_LOG_DIR"/node_*.log 2>/dev/null | grep -c -iE 'blacklist|banned|banning')
  pens=$(cat "$RIG_LOG_DIR"/node_*.log 2>/dev/null | grep -c -iE 'penaliz|penalty|misbehav')
  note "log lines: ban/blacklist $bans, penalty $pens"
  [[ "$bans" -gt 0 ]] && { grep -h -iE 'blacklist|banned|banning' "$RIG_LOG_DIR"/node_*.log | head -5 | cut -c1-240 | sed 's/^/  /'; fails+=" bans($bans)"; }
  [[ "$pens" -gt 0 ]] && grep -H -iE 'penaliz|penalty|misbehav' "$RIG_LOG_DIR"/node_*.log | head -5 | sed "s#^$RIG_LOG_DIR/##" | cut -c1-240 | sed 's/^/  /'
  if [[ -z "$fails" ]]; then upg_end PASS "baseline $vB and candidate $vC followed each other both ways; final height $h3"
  else upg_end FAIL "failed:$fails"; fi
}
upgrade_mixed
