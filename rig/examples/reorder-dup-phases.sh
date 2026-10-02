# reorder-dup-phases: blocks and payments across a relay when live links reorder and duplicate packets.
# A mines into its wallet, B relays, C holds a second wallet; every direction of A-B and B-C gets a 30 ms (10 ms
# jitter) delay with RD_REORDER of packets sent at once (out of order) and RD_DUP duplicated. A pays C RD_TXS times.
# Claim: every accepted payment reaches C's wallet, and A and C end on one chain and state, within the waits.
# Control: RD_CONTROL=cut partitions A-B before the payments, so C's balance wait must time out (FAIL).
# Env: RD_REORDER (5%), RD_DUP (3%), RD_TXS (10), RD_NANOERG (0.1 ERG), RD_CONTROL (cut).
# shellcheck source=rig/lib/phases.sh
source "$(dirname "$(readlink -f "$HOOK")")/../lib/phases.sh"
phases <<EOF
wait height A >= 12 timeout 240
wait balance A >= ${RD_NANOERG:-100000000}*${RD_TXS:-10}+200000000 timeout 240
wait same_chain A C SAME timeout 240
mark shaped
link_netem A B delay 30ms 10ms reorder ${RD_REORDER:-5%} 50% duplicate ${RD_DUP:-3%}
link_netem B A delay 30ms 10ms reorder ${RD_REORDER:-5%} 50% duplicate ${RD_DUP:-3%}
link_netem B C delay 30ms 10ms reorder ${RD_REORDER:-5%} 50% duplicate ${RD_DUP:-3%}
link_netem C B delay 30ms 10ms reorder ${RD_REORDER:-5%} 50% duplicate ${RD_DUP:-3%}
when RD_CONTROL=cut partition A B
record h0 height A
pay A C ${RD_NANOERG:-100000000} ${RD_TXS:-10}
floor value @pay_sent >= 1 timeout 0 cause NO_PAYMENTS
wait balance C >= @pay_sent*${RD_NANOERG:-100000000} timeout 240
wait same_chain A C SAME >= @h0+3 timeout 180
wait same_state A C SAME_OR_LAG timeout 120
EOF
