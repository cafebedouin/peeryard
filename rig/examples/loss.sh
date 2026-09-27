# loss: followers on lossy live links. A mines; B and C follow. Links start clean, so the bring-up gate passes; then
# A-B gets PEERYARD_LOSS % loss both ways (default 3) and A-C 10 % in the block-data direction only (A->C; C->A
# stays clean). A mines on for LOSS_RUN_S (default 120), then settle_follow slows and pauses A.
#   PEERYARD_LOSS        loss on A-B, both ways, in % (default 3)
#   LOSS_RUN_S           seconds A mines under loss before the settle (default 120)
#   LOSS_WINDOW_S        the window, from the moment the loss is applied (default 360)
#   LOSS_MARGIN_BLOCKS   blocks above A's height at the start of the hook that both followers must reach (default 30)
#   LOSS_CONTROL=partition   the designed failing control: partition A B instead of the loss; must FAIL
# PASS = within the window, same_state A B and same_state A C are both SAME at a height at least LOSS_MARGIN_BLOCKS
# above A's height at the start of the hook. What it cost is reported (costs.json, rig COSTS line), not judged.
LOSS=${PEERYARD_LOSS:-3}; RUN=${LOSS_RUN_S:-120}; WIN=${LOSS_WINDOW_S:-360}; MB=${LOSS_MARGIN_BLOCKS:-30}
note(){ echo "[loss] $*"; }
h0=$(full_height A); target=$((h0 + MB)); note "A at the start of the hook: $h0; both followers must reach SAME at >= $target"
t0=$SECONDS
if [ "${LOSS_CONTROL:-}" = partition ]; then partition A B; note "control: A-B partitioned instead of lossy"
else link_netem A B "loss ${LOSS}%"; link_netem B A "loss ${LOSS}%"; link_netem A C "loss 10%"; fi
note "qdiscs in A's namespace:"; ip netns exec "${NS[A]}" tc qdisc show | grep netem | sed 's/^/  /'
note "qdiscs in B's and C's namespaces:"; for x in B C; do ip netns exec "${NS[$x]}" tc qdisc show | grep netem | sed "s/^/  $x: /"; done
mark loss-applied
sleep "$RUN"
note "after ${RUN}s: A=$(full_height A) B=$(full_height B) C=$(full_height C)"
left=$((t0 + WIN - SECONDS)); [ $left -lt 30 ] && left=30
settle_follow A B "$target" "$left"; rb=$?
note "settle A-B: $SETTLE_STATE (after pause: $SETTLE_AFTER, ${SETTLE_WAIT_S}s)"
sc=""; while [ $SECONDS -lt $((t0 + WIN)) ]; do sc=$(same_state A C); case "$sc" in SAME@*) break ;; esac; sleep 3; done
[ -z "$sc" ] && sc=$(same_state A C)
sb=$(same_state A B)
note "final: same_state A B = $(echo "$sb" | cut -c1-40); same_state A C = $(echo "$sc" | cut -c1-40); t+$((SECONDS - t0))s of ${WIN}s"
note "data_mb A=$(data_mb A) B=$(data_mb B) C=$(data_mb C)"
ok(){ case "$1" in SAME@*) h=${1#SAME@}; [ "${h%%:*}" -ge "$target" ] ;; *) return 1 ;; esac; }
if [ $rb = 0 ] && ok "$sb" && ok "$sc"; then echo "LOSS: PASS"; rig_verdict=PASS
else echo "LOSS: FAIL (A-B: $(echo "$sb" | cut -c1-24), A-C: $(echo "$sc" | cut -c1-24), target >= $target)"; rig_verdict=FAIL; fi
