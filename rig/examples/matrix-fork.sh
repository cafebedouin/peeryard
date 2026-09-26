# matrix-fork: an ordering and input-block fork on the Matrix line, then its resolution. Two Matrix miners A and C
# with a follower B between them (A - B - C). Phase 1: all three share a chain. Phase 2: the B - C link is cut for
# MATRIX_FORK_S seconds while both miners keep mining, so C builds its own ordering blocks and input chains. Phase 3:
# the link is healed and C stops mining; the network must settle on one ordering chain (the heavier one, whichever
# miner built it) and B and C must rebuild the input chain on top of it.
#   PEERYARD_MATRIX_JAR=<weak-blocks jar> bash rig/rig.sh rig/examples/matrix-fork.json rig/examples/matrix-fork.sh
#   MATRIX_FORK_S partition length (default 120); MATRIX_SETTLE_S settle window after the heal (default 300)
#   MATRIX_FORK_DEPTH=<n>: hold the partition until both miners are n blocks past the cut (at most MATRIX_FORK_MAX_S,
#   default 600), instead of MATRIX_FORK_S; the run is INCONCLUSIVE if the fork came out shallower than n
#   (matrix-fork-deep sets 20). Every run reports the fork point and depth.
# INCONCLUSIVE = no shared chain before the cut, so the fork was never tested.
# PASS = a fork formed (A and C held different header ids at a height during the cut), after the heal all three
# agree by header id, B's and C's input chains match A's or are a prefix of it, the state roots agree with A
# paused, and the peer sets match the topology. The fork depth and which side won are reported.
FORK=${MATRIX_FORK_S:-120}; SETTLE=${MATRIX_SETTLE_S:-300}; fail=0
settle(){ local end=$((SECONDS + 240)); while [ $SECONDS -lt $end ]; do
  [ "$(same_chain A B | cut -c1-4)" = SAME ] && [ "$(same_chain A C | cut -c1-4)" = SAME ] && [ "$(full_height A)" -ge "$1" ] && return 0; sleep 3; done; return 1; }
# C is launched only once A has a genesis block, pinned to it: two miners started together can each mine their own
# genesis and never share a chain (seen 2026-09-25: A and C on different genesis blocks, B following C)
end=$((SECONDS + 120)); until [ -n "$(header_at A 1)" ] || [ $SECONDS -ge $end ]; do sleep 2; done
gen=$(genesis_id A) || { echo "[matrix-fork] FAIL: A gave no well-formed genesis id"; rig_verdict=FAIL; return; }; CONF_OVR[C]="ergo.chain.genesisId=\"$gen\""
launch C; wait_up C || echo "[matrix-fork] C did not answer on REST after its launch"
echo "[matrix-fork] phase 1: shared chain (C pinned to A's genesis ${gen:0:16})"
if ! settle 8; then
  # no shared chain before the cut (e.g. the miners started on disjoint chains): nothing about the fork was tested
  echo "[matrix-fork] INCONCLUSIVE: the three nodes never shared a chain before the cut (A=$(full_height A) B=$(full_height B) C=$(full_height C); A,B $(same_chain A B); A,C $(same_chain A C))"
  rig_verdict=INCONCLUSIVE; rig_cause=SETUP_NO_SHARED_CHAIN; echo "[matrix-fork] === MATRIX-FORK: $rig_verdict ==="; echo "MATRIX-FORK-DONE"; return 0
fi
h0=$(full_height A); DEPTH=${MATRIX_FORK_DEPTH:-}
if [ -n "$DEPTH" ]; then
  FMAX=${MATRIX_FORK_MAX_S:-600}; echo "[matrix-fork] phase 2: cut B-C at A.h=$h0 until both miners are $DEPTH blocks past it (at most ${FMAX}s)"
  partition B C; end=$((SECONDS + FMAX))
  until { [ "$(full_height A)" -ge $((h0 + DEPTH)) ] && [ "$(full_height C)" -ge $((h0 + DEPTH)) ]; } 2>/dev/null || [ $SECONDS -ge $end ]; do sleep 5; done
else
  echo "[matrix-fork] phase 2: cut B-C at A.h=$h0 for ${FORK}s"; partition B C; sleep "$FORK"
fi
ha=$(full_height A); hc=$(full_height C); lo=$(( ha < hc ? ha : hc ))
# the fork point: the first height at which A and C hold different header ids; the depth counts the shorter side's
# blocks since it (a full V2 sync summary reaches tip-16 on a young chain, so depth > 16 is the case it can miss)
fp=""; for ((h = (h0 > 5 ? h0 - 5 : 1); h <= lo; h++)); do [ "$(header_at A "$h")" != "$(header_at C "$h")" ] && { fp=$h; break; }; done
depth=$([ -n "$fp" ] && echo $((lo - fp + 1)) || echo 0); echo "[matrix-fork] fork point ${fp:-none}, depth $depth (heights A=$ha C=$hc)"
ida=$(header_at A "$lo"); idc=$(header_at C "$lo"); forked=$([ -n "$ida" ] && [ -n "$idc" ] && [ "$ida" != "$idc" ] && echo yes || echo no)
echo "[matrix-fork] during the cut: A.h=$ha C.h=$hc; at $lo A=${ida:0:8} C=${idc:0:8} forked=$forked; input chains A=$(input_chain_ids A | wc -l) C=$(input_chain_ids C | wc -l)"
[ "$forked" = yes ] || { echo "[matrix-fork] FAIL: no fork formed"; fail=1; }
echo "[matrix-fork] phase 3: heal B-C, C stops mining"; heal B C; stop_mining C >/dev/null; t0=$SECONDS
ok=no; end=$((SECONDS + SETTLE))
while [ $SECONDS -lt $end ]; do
  if [ "$(same_chain A B | cut -c1-4)" = SAME ] && [ "$(same_chain A C | cut -c1-4)" = SAME ]; then ok=yes; break; fi; sleep 3; done
winner=$([ "$(header_at A "$lo")" = "$ida" ] && echo "A's side" || echo "C's side")
echo "[matrix-fork] converged=$ok after $((SECONDS - t0)) s; the chain kept at $lo is $winner"
[ $ok = yes ] || fail=1
icb=$(same_input_chain_stable A B); icc=$(same_input_chain_stable A C)
stop_mining A >/dev/null
stb=NOHEIGHT; stc=NOHEIGHT; for _ in $(seq 1 30); do stb=$(same_state A B); stc=$(same_state A C)
  case "$stb/$stc" in SAME@*/SAME@*|DIFF@*/*|*/DIFF@*) break ;; esac; sleep 2; done
echo "[matrix-fork] input_chain A,B=$icb A,C=$icc; same_state A,B=${stb%%:*} A,C=${stc%%:*}"
for r in "$icb" "$icc"; do case "$r" in SAME@*|PREFIX@*) ;; *) fail=1 ;; esac; done
for r in "$stb" "$stc"; do case "$r" in SAME@*) ;; *) fail=1 ;; esac; done
echo "[matrix-fork] peers vs topology:"; check_topology_wait || fail=1
if [ $fail = 0 ]; then rig_verdict=PASS; else rig_verdict=FAIL; fi
if [ -n "$DEPTH" ] && [ "$depth" -lt "$DEPTH" ]; then
  echo "[matrix-fork] INCONCLUSIVE: the fork is $depth deep, $DEPTH was asked for; the deep case was not tested"
  rig_verdict=INCONCLUSIVE; rig_cause=FORK_TOO_SHALLOW
fi
echo "[matrix-fork] === MATRIX-FORK: $rig_verdict ==="; echo "MATRIX-FORK-DONE"
