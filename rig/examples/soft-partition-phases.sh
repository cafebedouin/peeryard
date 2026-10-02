# soft-partition-phases: fork resolution when the link between two mining groups is slow rather than cut.
# A-B and C-D are the groups (A and D mine), B-C the only bridge. The bridge gets a multi-second delay both ways
# while both sides keep mining, then heal puts its configured 10 ms back. Claim: the four nodes end on one chain,
# past the height at the end of the slow period, within SOFT_SYNC_S. Control: SOFT_CONTROL=cut partitions the
# bridge after the heal, so the groups mine apart and the cross-group wait must time out (FAIL).
# Env: SOFT_DELAY (4000ms), SOFT_HOLD_S (60), SOFT_SYNC_S (180), SOFT_CONTROL (cut).
# shellcheck source=rig/lib/phases.sh
source "$(dirname "$(readlink -f "$HOOK")")/../lib/phases.sh"
phases <<EOF
floor same_chain A D SAME >= 4 timeout 180
floor same_chain B C SAME >= 4 timeout 120
record h0 height A
mark soft-on
link_netem B C delay ${SOFT_DELAY:-4000ms}
link_netem C B delay ${SOFT_DELAY:-4000ms}
sleep ${SOFT_HOLD_S:-60}
record h1 height A
floor value @h1 > @h0 timeout 0 cause NO_GROWTH
mark soft-off
heal B C
when SOFT_CONTROL=cut partition B C
wait same_chain A D SAME >= @h1+2 timeout ${SOFT_SYNC_S:-180}
wait same_chain B C SAME >= @h1+2 timeout ${SOFT_SYNC_S:-180}
wait same_chain A B SAME >= @h1+2 timeout 60
EOF
