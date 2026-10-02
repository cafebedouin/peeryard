# soft-partition-race-phases: a measurement, not in the suite. The same groups and slow bridge as
# soft-partition-phases, past height 128 the same way, but D mines at A's poll and both keep mining after the heal.
# On this devnet each miner adds one block per mine_poll, so two miners at the same poll on separate forks can stay
# tied for as long as nothing breaks the tie. The scenario asserts nothing about convergence: it observes for
# RACE_OBSERVE_S after the heal and passes when the topology is intact. The time to converge is the rig's
# costs.json `agree_s` for the `heal B C` event (censored as never_agreed when the window ends first).
# Env: SOFT_DELAY (4000ms), SOFT_HOLD_S (60), RACE_OBSERVE_S (600).
# shellcheck source=rig/lib/phases.sh
source "$(dirname "$(readlink -f "$HOOK")")/../lib/phases.sh"
phases <<EOF
floor height A >= 130 timeout 480
floor same_chain A D SAME >= 130 timeout 120
start_mining D 2s
floor same_chain C D SAME >= 130 timeout 120
record h0 height A
floor value @h0 > 128 timeout 0 cause YOUNG_CHAIN
link_netem B C delay ${SOFT_DELAY:-4000ms}
link_netem C B delay ${SOFT_DELAY:-4000ms}
sleep ${SOFT_HOLD_S:-60}
record h1 height A
floor value @h1-@h0 < 128 timeout 0 cause FORK_DEPTH
heal B C
sleep ${RACE_OBSERVE_S:-600}
record h_end height A
pass links: topology
EOF
