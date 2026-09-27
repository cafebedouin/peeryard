# three-body: three nodes, two close (A-B, 5 ms) and one far (C, 150 ms each way from both, no jitter: netem jitter
# reorders packets, which TCP reads as loss), each pinned to its own CPUs ("cpus"). One hook, three topologies:
#   three-body-close-strong.json    A (cpus 0-1) and B (2-3) mine; C (cpu 4) follows          needs 5 CPUs
#   three-body-far-strong.json      C (cpus 0-3) mines; A (4) and B (5) follow                 needs 6 CPUs
# A node on one CPU runs a different collector (JDK 21 picks SerialGC under a 1-CPU mask, G1 under 2): that is part of
# the condition, and each launch event records the collector. On WSL2 two CPUs may be two hyperthreads of one core,
# so "strong" is nominal there. (A third shape, two miners on unequal CPUs, was dropped: on the devnet the difficulty
# stays at its minimum and each internal miner produces one block per poll, so CPUs do not change a miner's block
# count; witnessed 133 against 130 blocks for 3 CPUs against 1.)
# After a floor (all three on one chain) and a mined prefix, C is partitioned from A and B for THREEBODY_SPLIT_S (60)
# and healed; the miners mine on for THREEBODY_AFTER_S (180; agree_s after a partition includes TCP's own recovery).
# costs.json has agree_s for each heal (C's recovery, or A's and B's in far-strong) and the weak nodes' loopback /info
# times. Then every miner but the first is paused, settle_follow pauses the first, and:
# PASS = all three same_state SAME at a height at least THREEBODY_MARGIN_BLOCKS (10) above the leader's full height at
# the heal (read by this hook), within THREEBODY_SETTLE_S (240) of the settle's start.
#   THREEBODY_CONTROL=no-heal   the designed failing control: skip the heal; must FAIL
# It prints each miner's count of locally mined blocks (node log: "locally generated modifier ... of type 101").
SPLIT=${THREEBODY_SPLIT_S:-60}; AFTER=${THREEBODY_AFTER_S:-180}; MB=${THREEBODY_MARGIN_BLOCKS:-10}; SW=${THREEBODY_SETTLE_S:-240}
PREFIX=${THREEBODY_PREFIX_BLOCKS:-20}
note(){ echo "[three-body] $*"; }
mapfile -t MINERS < <(jq -r '.nodes[] | select(.mining) | .name' "$CFG")
mapfile -t FOLLOWERS < <(jq -r '.nodes[] | select(.mining | not) | .name' "$CFG")
L=${MINERS[0]}
note "miners: ${MINERS[*]} (leader $L); followers: ${FOLLOWERS[*]}; cpus: $(jq -r '[.nodes[] | "\(.name)=\(.cpus)"] | join(" ")' "$CFG")"
note "floor and prefix: every node on $L's chain, $PREFIX blocks above the start"
h_start=$(full_height "$L"); end=$((SECONDS + 240)); floor=no
while [ $SECONDS -lt $end ]; do
  ok=yes; for x in A B C; do [ "$x" = "$L" ] && continue; case "$(same_chain "$L" "$x")" in SAME@*) ;; *) ok=no ;; esac; done
  [ $ok = yes ] && [ "$(full_height "$L")" -ge $((h_start + PREFIX)) ] && { floor=yes; break; }; sleep 3
done
[ $floor = yes ] || { note "floor FAIL"; echo "THREE-BODY: INCONCLUSIVE (no floor)"; rig_verdict=INCONCLUSIVE; return 0 2>/dev/null || exit 0; }
note "floor OK: A=$(full_height A) B=$(full_height B) C=$(full_height C)"
partition A C; partition B C
sleep "$SPLIT"
h_heal=$(full_height "$L")
note "at the heal: A=$(full_height A) B=$(full_height B) C=$(full_height C) (leader $L at $h_heal)"
if [ "${THREEBODY_CONTROL:-}" = no-heal ]; then note "control: no heal"; else heal A C; heal B C; fi
sleep "$AFTER"
note "after ${AFTER}s: A=$(full_height A) B=$(full_height B) C=$(full_height C)"
for m in "${MINERS[@]}"; do [ "$m" = "$L" ] || stop_mining "$m" >/dev/null; done
target=$((h_heal + MB)); t_settle=$SECONDS
first=""; for x in A B C; do [ "$x" != "$L" ] && { first=$x; break; }; done
settle_follow "$L" "$first" "$target" "$SW"; rs=$?
note "settle $L-$first: $SETTLE_STATE (after pause: $SETTLE_AFTER, ${SETTLE_WAIT_S}s)"
fails=""
for x in A B C; do
  [ "$x" = "$L" ] && continue
  st=""; while [ $SECONDS -lt $((t_settle + SW)) ]; do st=$(same_state "$L" "$x"); case "$st" in SAME@*) break ;; esac; sleep 3; done
  [ -z "$st" ] && st=$(same_state "$L" "$x")
  note "same_state $L $x: $(echo "$st" | cut -c1-40)"
  case "$st" in SAME@*) h=${st#SAME@}; [ "${h%%:*}" -ge "$target" ] || fails="$fails $x(below $target)" ;; *) fails="$fails $x(${st%% *})" ;; esac
done
[ $rs = 0 ] || fails="$fails settle"
for m in "${MINERS[@]}"; do note "blocks mined by $m: $(grep -c 'locally generated modifier .* of type 101' "$RIG_LOG_DIR/node_$m.log")"; done
note "data_mb A=$(data_mb A) B=$(data_mb B) C=$(data_mb C)"
if [ -z "$fails" ]; then echo "THREE-BODY: PASS (all three SAME at >= $target)"; rig_verdict=PASS
else echo "THREE-BODY: FAIL (not SAME with $L at >= $target:$fails)"; rig_verdict=FAIL; fi
