# flap: a link that goes down and comes back on a schedule. A mines, B follows; after bring-up and a floor (B on A's
# chain), `flap A B <down> <up> <cycles>` (default 10 s down, 30 s up, 6 cycles). What recovery cost per cycle is in
# costs.json (one heal per cycle, detail "flap i/N"); a cycle whose agree_s is censored is one where B and A were not
# seen on the same tip at two consecutive samples before the next cut (under a live miner that is common, and it is
# a limit of the measure, not a failure).
#   FLAP_DOWN_S, FLAP_UP_S, FLAP_CYCLES   the schedule (10, 30, 6)
#   FLAP_MARGIN_S       seconds after the last up period that the window allows for the settle (default 150)
#   FLAP_MARGIN_BLOCKS  blocks above A's height at the last edge that B must reach (default 3)
#   FLAP_CONTROL=down-edge   the designed failing control: end on a cut (partition A B, no heal); must FAIL
# PASS = within the window fixed from the flap's start (cycles x (down + up) + FLAP_MARGIN_S), same_state A B is SAME at
# a height at least FLAP_MARGIN_BLOCKS above A's full height at the last edge (read by this hook), after A's miner is
# slowed and paused by settle_follow.
DOWN=${FLAP_DOWN_S:-10}; UP=${FLAP_UP_S:-30}; CYC=${FLAP_CYCLES:-6}; MS=${FLAP_MARGIN_S:-150}; MB=${FLAP_MARGIN_BLOCKS:-3}
note(){ echo "[flap] $*"; }
note "floor: B on A's chain"
end=$((SECONDS + 120)); sc=""
while [ $SECONDS -lt $end ]; do sc=$(same_chain A B); case "$sc" in SAME@*) h=${sc#SAME@}; [ "${h%%:*}" -ge 4 ] && break ;; esac; sleep 3; done
case "$sc" in SAME@*) note "floor OK ($(echo "$sc" | cut -c1-12))" ;; *) note "floor FAIL ($sc)"; echo "FLAP: INCONCLUSIVE (no floor)"; rig_verdict=INCONCLUSIVE; return 0 2>/dev/null || exit 0 ;; esac
t_start=$SECONDS; win_end=$((t_start + CYC * (DOWN + UP) + MS))
note "flap A B ${DOWN}s down / ${UP}s up x $CYC; window ends at t+$((win_end - t_start))s"
mark flap-start
flap A B "$DOWN" "$UP" "$CYC"
h_last=$FLAP_LAST_HEIGHT; edge="the last heal"
if [ "${FLAP_CONTROL:-}" = down-edge ]; then partition A B; h_last=$(full_height A); edge="a final cut (control: partition A B, no heal)"; fi
target=$((h_last + MB)); note "A's full height at the last edge ($edge): $h_last; B must reach SAME at >= $target"
left=$((win_end - SECONDS)); [ $left -lt 30 ] && left=30
settle_follow A B "$target" "$left"; rc=$?
bf=$(full_height B)
note "settle: $SETTLE_STATE (after pause: $SETTLE_AFTER; ${SETTLE_WAIT_S}s; A mined $SETTLE_TRICKLE in the settle)"
note "data_mb A=$(data_mb A) B=$(data_mb B)"
if [ $rc = 0 ]; then echo "FLAP: PASS (B SAME with A at >= $target within the window)"; rig_verdict=PASS
else echo "FLAP: FAIL (clause: same_state A B SAME at >= A's last-edge height $h_last + $MB within the window; A at the last edge $h_last, B final $bf, last state $SETTLE_STATE)"; rig_verdict=FAIL; fi
