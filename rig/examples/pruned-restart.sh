# pruned-restart: does a node that prunes full blocks still prune every old height after a restart, and after an
# upgrade in place? A mines; C and D prune (blocksToKeep 20). D stays up throughout: the control, whose floor moves
# by the usual per-block steps. C is cut from A and restarted (stop with SIGTERM, start over the same data directory)
# while its floor is still at a voting-epoch start, and stays cut while A mines past the height at which the floor
# moves to the next epoch start. Then the cut is healed.
#
# Why that shape: the floor (the lowest height whose full block is kept) is `tip - blocksToKeep + 1`, but never later
# than the start of its voting epoch (votingLength 128 on the devnet). It therefore stays at 128 from tip 148 to tip 274,
# then moves to 256 in one step. A restarted node does not know that its headers are synced; the first header younger
# than `headerChainDiff` block intervals marks them synced and stores the floor for that header before any block is
# applied. If that header is past the epoch move, the stored floor moves past heights that were never pruned.
# `headerChainDiff` 10 (20 s on the 2 s devnet) scales the node's 200-block window to a run of minutes; ergo's own
# PrunedDigestNodeSync2Spec sets it to 20 for the same reason.
#
# The restart must happen with C at 256 or above: a floor stored above the node's best full block plus one leaves
# blocks it can no longer download (ergo #1159), a different failure that this scenario does not test.
#
# Topologies:
#   pruned-restart.json   C runs PEERYARD_JAR before and after its restart
#   pruned-upgrade.json   C runs PEERYARD_JAR_B (the baseline) before the stop and PEERYARD_JAR after it
#
# Checks, at A's final height TOP, after A stops mining and C and D reach TOP on A's chain:
#   floor   F = TOP - 19, or its voting-epoch start when F > votingLength (computed here, not read from the node)
#   pruned  no full block from height 2 to F - 1 is served (height 1 is not judged, as in ergo's own tests)
#   kept    every full block from F to TOP is served, and every header is kept
# PASS = C and D both pruned and kept. FAIL names the node and the heights still served below the floor. Before the
# restart, C's heights 2..127 must already be pruned (else INCONCLUSIVE: the store did not start clean).
# INCONCLUSIVE also when C was not cut inside the window (256..274), A never passed the epoch move, or C never synced.
#   PEERYARD_JAR=<candidate.jar> bash rig/rig.sh rig/examples/pruned-restart.json rig/examples/pruned-restart.sh
#   PEERYARD_JAR_B=<baseline.jar> PEERYARD_JAR=<candidate.jar> bash rig/rig.sh rig/examples/pruned-upgrade.json rig/examples/pruned-restart.sh
# Env: PR_VOTING (128: the chain's votingLength), PR_CUT_AT (256), PR_HEAL_AT (320: A's height at the heal),
#   PR_PRUNE_WAIT_S (60: heights still served are re-read this long, since pruning lands a step after a block).
V=${PR_VOTING:-128}; CUT_AT=${PR_CUT_AT:-256}; HEAL_AT=${PR_HEAL_AT:-320}; PWAIT=${PR_PRUNE_WAIT_S:-60}
note(){ echo "[pruned-restart] $*"; }
pr_end(){ echo "[pruned-restart] === PRUNED-RESTART: $1 ($2) ==="; rig_verdict=$1; [[ -n "${3:-}" ]] && rig_cause=$3; }
ver(){ rest "$1" /info | jq -r '.appVersion // "null"'; }
k_of(){ grep -h blocksToKeep "$SCRATCH/conf_$1.conf" | tail -1 | grep -oE '[0-9]+' | tail -1; }
# the floor the node computes for its best full block at height $1 (FullBlockPruningProcessor.updateBestFullBlock)
floor_at(){ local h=$(( $1 - K + 1 )); (( h < 1 )) && h=1; (( h > V )) && h=$(( h - h % V )); echo "$h"; }
# full block served at height $2 by node $1: the transaction count, "nohdr" when the header is gone, 0 when not served
served(){ local id; id=$(header_at "$1" "$2"); [[ -n "$id" ]] || { echo nohdr; return; }; rest "$1" "/blocks/$id" | jq -r '.blockTransactions.transactions | length // 0' 2>/dev/null || echo 0; }
# ranges "a-b c" from a list of heights
ranges(){ tr ' ' '\n' | grep -E '^[0-9]+$' | sort -n | awk 'NR==1{s=$1;p=$1;next} $1==p+1{p=$1;next} {printf "%s ", (s==p?s:s"-"p); s=$1;p=$1} END{if(NR) printf "%s", (s==p?s:s"-"p)}'; }
# prune_state NODE FLOOR TOP: sets KEPT (served below the floor, after re-reads), MISSING (not served from the floor
# to TOP) and NOHDR (headers gone), as range lists
prune_state(){
  local n="$1" fl="$2" top="$3" h s still list end
  list=$(seq 2 $((fl - 1)) | tr '\n' ' '); NOHDR=""; end=$((SECONDS + PWAIT))
  while :; do
    still=""
    for h in $list; do s=$(served "$n" "$h"); if [[ "$s" == nohdr ]]; then NOHDR+=" $h"; elif [[ "${s:-0}" =~ ^[0-9]+$ ]] && (( s >= 1 )); then still+=" $h"; fi; done
    list="${still# }"; [[ -z "$list" || $SECONDS -ge $end ]] && break; sleep 5
  done
  KEPT=$(echo "$list" | ranges); MISSING=""
  for h in $(seq "$fl" "$top"); do s=$(served "$n" "$h"); [[ "${s:-0}" =~ ^[0-9]+$ ]] && (( s >= 1 )) || MISSING+=" $h"; done
  MISSING=$(echo "$MISSING" | ranges); NOHDR=$(echo "$NOHDR" | ranges)
}

pruned_restart(){
  local cand base upgrade=no a c d hc st end top fl ver0 ver1 fails="" pre
  K=$(k_of C); [[ -n "$K" && "$K" == "$(k_of D)" ]] || { pr_end INCONCLUSIVE "C and D must share one blocksToKeep (C=${K:-none} D=$(k_of D))" SETUP; return; }
  grep -q votingLength "$SCRATCH/conf_C.conf" && note "WARN: the topology overrides votingLength; PR_VOTING=$V must match it"
  cand="$(readlink -f "${PEERYARD_JAR:-}")"
  [[ "$(readlink -f "${NODE_JAR[C]}")" != "$cand" ]] && upgrade=yes
  note "blocksToKeep $K, votingLength $V; C starts on $(basename "${NODE_JAR[C]}") ($(ver C)), A and D on $(basename "$cand") ($(ver D)); upgrade=$upgrade"

  # 1. C and D follow A until C reaches the cut height, with C's floor still at the epoch start below it
  end=$((SECONDS + 600))
  while [[ $SECONDS -lt $end ]]; do
    a=$(full_height A); c=$(full_height C); d=$(full_height D)
    [[ "${c:-0}" -ge "$CUT_AT" ]] && break
    (( SECONDS % 30 < 2 )) && note "mining: A=$a C=$c D=$d"
    sleep 1
  done
  [[ "${c:-0}" -ge "$CUT_AT" ]] || { pr_end INCONCLUSIVE "C never reached height $CUT_AT (A=$a C=$c D=$d)" NO_SYNC; return; }
  partition A C || { pr_end INCONCLUSIVE "partition A C failed" SETUP; return; }
  sleep 3; hc=$(full_height C)
  note "cut at C=$hc (A=$(full_height A) D=$(full_height D)); C's floor $(floor_at "$hc"); the epoch move is at tip $((2 * V + K - 1))"
  (( hc >= CUT_AT && $(floor_at "$hc") < CUT_AT )) || { pr_end INCONCLUSIVE "C was cut at $hc, outside $CUT_AT..$((2 * V + K - 2))" WINDOW; return; }
  [[ "$(same_chain A C | cut -c1-4)" == SAME ]] || { pr_end INCONCLUSIVE "C was not on A's chain at the cut ($(same_chain A C))" NO_SYNC; return; }

  # 2. before the restart: C's store is clean below its floor
  prune_state C "$(floor_at "$hc")" "$hc"; pre="kept below the floor: ${KEPT:-none}; missing: ${MISSING:-none}; headers gone: ${NOHDR:-none}"
  note "before the restart, C at $hc, floor $(floor_at "$hc"): $pre"
  [[ -z "$KEPT$MISSING$NOHDR" ]] || { pr_end INCONCLUSIVE "C's store was not clean before the restart ($pre)" PRE_DIRTY; return; }

  # 3. restart C (upgrade: on the candidate jar) while it is cut, so its headers stay marked unsynced
  ver0=$(ver C)
  if [[ $upgrade == yes ]]; then
    NODE_JAR[C]="$cand"
    [[ -n "${RUNTIME_CWD:-}" ]] || unzip -o -q "$cand" application.conf devnet.conf mainnet.conf testnet.conf -d "${RT_CWD[C]}/src/main/resources"
  fi
  mark restart-stop
  relaunch C || { pr_end FAIL "C did not come back after the restart" NO_RESTART; return; }
  mark restart-started; ver1=$(ver C)
  note "C restarted: $ver0 -> $ver1, full height $(full_height C), connected peers $(rest C /peers/connected | jq -r 'length' 2>/dev/null)"
  if [[ $upgrade == yes && "$ver1" == "$ver0" ]]; then pr_end INCONCLUSIVE "the upgrade did not change C's appVersion ($ver0)" SETUP; return; fi

  # 4. A mines past the epoch move while C is cut, then the cut heals; the headers C missed are older than its window
  end=$((SECONDS + 600)); while [[ $SECONDS -lt $end && "$(full_height A)" -lt "$HEAL_AT" ]]; do sleep 2; done
  a=$(full_height A); [[ "$a" -ge "$HEAL_AT" ]] || { pr_end INCONCLUSIVE "A never reached $HEAL_AT (A=$a)" NO_MINING; return; }
  heal A C; note "healed at A=$a, C=$(full_height C)"
  # C must start applying blocks while A still mines (a header younger than the window has to reach it)
  end=$((SECONDS + 180)); while [[ $SECONDS -lt $end && "$(full_height C)" -le $((hc + 5)) ]]; do sleep 2; done
  c=$(full_height C)
  (( c > hc + 5 )) || { pr_end FAIL "C did not apply blocks after the heal (C=$c, cut at $hc, A=$(full_height A))" STALL; return; }

  # 5. A stops; C and D settle at its height
  top=$(full_height A); stop_mining A; top=$(full_height A); end=$((SECONDS + 60)); while [[ $SECONDS -lt $end && "$top" -lt 1 ]]; do sleep 2; top=$(full_height A); done
  end=$((SECONDS + 240))
  while [[ $SECONDS -lt $end ]]; do [[ "$(full_height C)" -ge "$top" && "$(full_height D)" -ge "$top" ]] && break; sleep 3; done
  note "A stopped at $top; C=$(full_height C) D=$(full_height D); A-C $(same_chain A C | cut -c1-16) A-D $(same_chain A D | cut -c1-16)"
  [[ "$(full_height C)" -ge "$top" && "$(full_height D)" -ge "$top" ]] || { pr_end INCONCLUSIVE "C or D did not reach A's height $top" NO_SYNC; return; }
  fl=$(floor_at "$top")
  (( fl > $(floor_at "$hc") )) || { pr_end INCONCLUSIVE "A's final height $top does not move the floor past $(floor_at "$hc")" NO_MOVE; return; }

  # 6. the checks
  for n in D C; do
    prune_state "$n" "$fl" "$top"
    note "$n at $top, floor $fl: kept below the floor: ${KEPT:-none}; missing from the floor up: ${MISSING:-none}; headers gone: ${NOHDR:-none}"
    [[ -z "$KEPT$MISSING$NOHDR" ]] || fails+=" $n(kept ${KEPT:-none}; missing ${MISSING:-none}; nohdr ${NOHDR:-none})"
  done
  if [[ -z "$fails" ]]; then pr_end PASS "C ($ver0 -> $ver1) and D prune every height below $fl at $top"
  else pr_end FAIL "still served below the floor or lost:$fails" PRUNE; fi
}
pruned_restart
