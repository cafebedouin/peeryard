# revive-headroom: what a restart costs a follower with little CPU. A mines (cpus 0-1); B follows (cpus 4-7). B is
# crashed (SIGKILL), A mines on for REVIVE_DOWN_S, and B is revived pinned to REVIVE_CPUS (the arm: "4", "4-5" or
# "4-7", i.e. 1, 2 or 4 CPUs; set_cpus). costs.json reports, for the revive: first_answer_s (JVM start to REST),
# headers_advanced_s, agree_s, sync_s, loopback /info times and CPU seconds in the window; the launch event records the
# CPUs applied and the collector (SerialGC at one CPU on JDK 21). Needs 8 CPUs. Run each arm at least 3 times.
#   REVIVE_CPUS          B's CPUs at the revive (default 4-5)
#   REVIVE_DOWN_S        seconds B stays down while A mines (default 120)
#   REVIVE_AFTER_S       seconds A mines on after the revive before the settle (default 150)
#   REVIVE_MARGIN_BLOCKS blocks above A's height at the revive that B must reach (default 10)
#   REVIVE_CONTROL=partitioned   the designed failing control: revive B while it is partitioned from A; must FAIL
# PASS = same_state A B SAME at a height at least REVIVE_MARGIN_BLOCKS above A's full height at the revive (read by
# this hook), after settle_follow slows and pauses A (window 180 s).
CPUS=${REVIVE_CPUS:-4-5}; DOWN=${REVIVE_DOWN_S:-120}; AFTER=${REVIVE_AFTER_S:-150}; MB=${REVIVE_MARGIN_BLOCKS:-10}
note(){ echo "[revive-headroom] $*"; }
end=$((SECONDS + 120)); sc=""
while [ $SECONDS -lt $end ]; do sc=$(same_chain A B); case "$sc" in SAME@*) h=${sc#SAME@}; [ "${h%%:*}" -ge 10 ] && break ;; esac; sleep 3; done
case "$sc" in SAME@*) h=${sc#SAME@}; [ "${h%%:*}" -ge 10 ] || sc=short ;; esac
case "$sc" in SAME@*) note "floor OK ($(echo "$sc" | cut -c1-12))" ;; *) note "floor FAIL ($sc)"; echo "REVIVE-HEADROOM: INCONCLUSIVE (no floor)"; rig_verdict=INCONCLUSIVE; return 0 2>/dev/null || exit 0 ;; esac
crash B
note "B crashed at A=$(full_height A); A mines on for ${DOWN}s"
sleep "$DOWN"
set_cpus B "$CPUS"
[ "${REVIVE_CONTROL:-}" = partitioned ] && { partition A B; note "control: B revived while partitioned from A"; }
h_rev=$(full_height A); target=$((h_rev + MB))
note "revive B pinned to $CPUS at A=$h_rev; B must reach SAME at >= $target"
revive B
sleep "$AFTER"
note "after ${AFTER}s: A=$(full_height A) B=$(full_height B)"
settle_follow A B "$target" 180; rc=$?
note "settle: $SETTLE_STATE (after pause: $SETTLE_AFTER, ${SETTLE_WAIT_S}s)"
note "data_mb A=$(data_mb A) B=$(data_mb B)"
if [ $rc = 0 ]; then echo "REVIVE-HEADROOM: PASS (cpus $CPUS; B SAME with A at >= $target)"; rig_verdict=PASS
else echo "REVIVE-HEADROOM: FAIL (cpus $CPUS; B not SAME with A at >= $target: $SETTLE_STATE)"; rig_verdict=FAIL; fi
