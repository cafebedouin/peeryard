# reorg-mempool-phases: reorg-mempool.sh's claim as data (rig/PHASES.md): transactions confirmed on the losing side of
# a fork survive the reorg. The staging is reorg-mempool.sh's (its header comment explains each step); where that hook
# waits for several conditions in one loop, this one waits for them one after another.
# PASS = A strictly heavier at the heal, C and D back on A's chain and state, and D's confirmed balance still covers
# every accepted payment. INCONCLUSIVE = no payment accepted (NO_PAYMENTS), none confirmed on C's fork
# (NOT_CONFIRMED_ON_FORK), A's lead at the heal reached REORG_MAX_LEAD (STAGING_OVERSHOOT), or A and C not on
# different chains before the heal (NO_FORK).
# Env: REORG_TXS (default 10), REORG_NANOERG (0.1 ERG), REORG_MAX_LEAD (15).
# shellcheck source=rig/lib/phases.sh
source "$(dirname "$(readlink -f "$HOOK")")/../lib/phases.sh"
phases <<EOF
# floor: C mines the shared chain and matures its wallet; A and D follow
wait height C >= 12 timeout 240
wait balance C >= ${REORG_NANOERG:-100000000}*${REORG_TXS:-10}+200000000 timeout 240
wait same_chain C A SAME timeout 240
wait same_chain C D SAME timeout 240
# settle: pause C; A and D fully sync to C's tip (full height == header height) so A can mine once isolated
stop_mining C
floor height C > 0 timeout 90
record hshared height C
wait height A >= @hshared timeout 120
wait height D >= @hshared timeout 120
wait synced A timeout 120
wait synced D timeout 120
# split: A mines its fork; C resumes briefly and pays D from shared-prefix rewards, then is frozen
partition A C
start_mining A 3s
start_mining C 1500ms
sleep 2
pay C D ${REORG_NANOERG:-100000000} ${REORG_TXS:-10}
floor value @pay_sent >= 1 timeout 0 cause NO_PAYMENTS
floor balance D >= @pay_sent*${REORG_NANOERG:-100000000} timeout 120 cause NOT_CONFIRMED_ON_FORK
stop_mining C
floor height C > 0 timeout 90
record hc height C
wait height A >= @hc+3 timeout 180
stop_mining A
floor height A > 0 timeout 90
record ha height A
pass overtook: height A > @hc
floor height A < @hc+${REORG_MAX_LEAD:-15} timeout 0 cause STAGING_OVERSHOOT
floor same_chain A C DIFF timeout 0 cause NO_FORK
# heal: restore the link, relaunch A mining slowly; C and D reorganise onto A's chain and re-confirm the payments
heal A C
start_mining A 3s
wait same_chain A C SAME timeout 200
wait same_state A C SAME_OR_LAG timeout 200
wait same_chain A D SAME timeout 200
wait height A >= @ha timeout 200
record ah height A
wait height C >= @ah-5 timeout 200
wait height D >= @ah-5 timeout 200
wait balance D >= @pay_sent*${REORG_NANOERG:-100000000} timeout 180
EOF
