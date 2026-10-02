# mixed-roles-phases: a digest follower (B) and a pruned follower (C, blocksToKeep 20) of a full miner (A), 40 ms
# links, through a partition with a crash in it. B is cut from A, killed and revived while still cut, so its height
# can come only from its own disk; then healed. C is cut while A mines, then healed. Claim: B restores at least its
# pre-crash height from disk, and after the heals both followers reach A's chain and, with A stopped, A's state
# root at A's final height. Control: MR_CONTROL=down crashes B again after its heal and leaves it down, so the
# B waits must time out (FAIL).
# Env: MR_HOLD_S (30), MR_SYNC_S (180), MR_CONTROL (down).
# shellcheck source=rig/lib/phases.sh
source "$(dirname "$(readlink -f "$HOOK")")/../lib/phases.sh"
phases <<EOF
floor same_chain A B SAME >= 6 timeout 180
floor same_chain A C SAME >= 6 timeout 180
partition A B
record hb0 height B
crash B
revive B
wait height B >= @hb0 timeout 90
sleep ${MR_HOLD_S:-30}
heal A B
when MR_CONTROL=down crash B
partition A C
sleep ${MR_HOLD_S:-30}
heal A C
record h1 height A
wait same_chain A B SAME >= @h1+2 timeout ${MR_SYNC_S:-180}
wait same_chain A C SAME >= @h1+2 timeout ${MR_SYNC_S:-180}
stop_mining A
floor height A > 0 timeout 90
record hs height A
wait same_state A B SAME >= @hs timeout 120
wait same_state A C SAME >= @hs timeout 120
EOF
