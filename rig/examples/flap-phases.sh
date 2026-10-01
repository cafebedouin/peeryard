# flap-phases: flap.sh's claim as data (rig/PHASES.md). A mines and B follows; after a floor (B on A's chain at >= 4),
# the A-B link goes down and comes back on a schedule (flap.sh's knobs and defaults). PASS = settle_follow brings B to
# SAME with A at a height at least FLAP_MARGIN_BLOCKS above A's full height at the last edge, within FLAP_MARGIN_S.
# (flap.sh gives the settle what is left of a window fixed at the flap's start, never under 30 s; here the settle gets
# FLAP_MARGIN_S itself, a few seconds more.)
#   FLAP_DOWN_S, FLAP_UP_S, FLAP_CYCLES (10, 30, 6), FLAP_MARGIN_S (150), FLAP_MARGIN_BLOCKS (3)
#   FLAP_CONTROL=down-edge   the designed failing control: end on a cut (partition A B, no heal); must FAIL
# shellcheck source=rig/lib/phases.sh
source "$(dirname "$(readlink -f "$HOOK")")/../lib/phases.sh"
phases <<EOF
floor same_chain A B SAME >= 4 timeout 120
mark flap-start
flap A B ${FLAP_DOWN_S:-10} ${FLAP_UP_S:-30} ${FLAP_CYCLES:-6}
record h_last flap_last
when FLAP_CONTROL=down-edge partition A B
when FLAP_CONTROL=down-edge record h_last height A
settle_follow A B @h_last+${FLAP_MARGIN_BLOCKS:-3} ${FLAP_MARGIN_S:-150}
pass settled: settle
EOF
