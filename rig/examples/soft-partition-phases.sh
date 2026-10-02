# soft-partition-phases: fork resolution when the link between two mining groups is slow rather than cut.
# A-B and C-D are the groups, B-C the only bridge. A mines from launch; D starts mining at a slower poll once the
# chain is past height 128 and shared, so A's fork is the heavier one by construction and no node restarts after
# the fork. The bridge gets a multi-second delay both ways while both mine, so the groups fork; then it heals.
# Claim: all four nodes are on A's chain within SOFT_SYNC_S of the heal. Control: SOFT_CONTROL=cut partitions the
# bridge instead of healing it, which must FAIL.
# Guards (INCONCLUSIVE, not FAIL): YOUNG_CHAIN if the fork starts at or below height 128, FORK_DEPTH if it reaches
# 128 blocks. Forks deeper than the sync summaries reach are a separate backlog item (ROADMAP.md, *Scenario
# backlog*, deep forks on young chains), not the condition claimed here.
# Two miners at the same poll on separate forks are a tie on this devnet (soft-partition-race-phases measures that).
# Env: SOFT_DELAY (4000ms), SOFT_HOLD_S (60), SOFT_SYNC_S (180), SOFT_D_POLL (6s), SOFT_CONTROL (cut).
# shellcheck source=rig/lib/phases.sh
source "$(dirname "$(readlink -f "$HOOK")")/../lib/phases.sh"
phases <<EOF
floor height A >= 130 timeout 480
floor same_chain A D SAME >= 130 timeout 120
start_mining D ${SOFT_D_POLL:-6s}
floor same_chain C D SAME >= 130 timeout 120
record h0 height A
floor value @h0 > 128 timeout 0 cause YOUNG_CHAIN
mark soft-on
link_netem B C delay ${SOFT_DELAY:-4000ms}
link_netem C B delay ${SOFT_DELAY:-4000ms}
sleep ${SOFT_HOLD_S:-60}
record h1 height A
floor value @h1 > @h0 timeout 0 cause NO_GROWTH
floor value @h1-@h0 < 128 timeout 0 cause FORK_DEPTH
mark soft-off
heal B C
when SOFT_CONTROL=cut partition B C
wait same_chain A D SAME >= @h1+2 timeout ${SOFT_SYNC_S:-180}
wait same_chain B C SAME >= @h1+2 timeout ${SOFT_SYNC_S:-180}
wait same_chain A B SAME >= @h1+2 timeout 60
EOF
