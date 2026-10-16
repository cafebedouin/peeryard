# reorg-mempool-phases: reorg-mempool.sh's claim as data (rig/PHASES.md): transactions confirmed on the losing side of
# a fork survive the reorg. The staging is reorg-mempool.sh's (its header comment explains each step); where that hook
# waits for several conditions in one loop, this one waits for them one after another.
# PASS = A strictly heavier at the heal, C and D back on A's chain and state, and D's confirmed balance still covers
# every accepted payment. INCONCLUSIVE = no payment accepted (NO_PAYMENTS), none confirmed on C's fork
# (NOT_CONFIRMED_ON_FORK), A's lead at the heal reached REORG_MAX_LEAD (STAGING_OVERSHOOT), or A and C not on
# different chains before the heal (NO_FORK).
# Env: REORG_TXS (default 10), REORG_NANOERG (0.1 ERG), REORG_MAX_LEAD (15), REORG_CONFIRM_WAIT_S (180: the final wait
# for D's confirmed balance; each new count of re-confirmed payments is logged with its time after the heal,
# `[reorg] confirmed k/N at t s after heal`, then `[reorg] time to N/N after heal: t s` or `not reached`).

# reorg_confirmed <node> <nanoERG per payment> <wait s>: the final wait, run inside one `fn` evaluation so it can log as
# it polls; the phase line has `timeout 0`, so a false return is that wait's timeout (FAIL, WAIT_TIMEOUT:<line>). It
# polls as a phases wait does (every 3 s until the deadline) for <node>'s balance >= @pay_sent payments (phases.sh's
# record, read from _PH_REC), and times each new count (balance / amount, a new maximum) from the rig's last heal event.
reorg_confirmed(){
  local n=$1 amt=$2 w=$3 sent=${_PH_REC[pay_sent]:-0} b k kmax=0 th end
  th=$(jq -r 'select(.kind == "heal") | .t' "$RIG_LOG_DIR/events.jsonl" 2>/dev/null | tail -1)
  [[ $th =~ ^[0-9]+$ ]] || { th=$(date +%s%3N); echo "[reorg] no heal event read: times are from the start of the wait"; }
  echo "[reorg] confirmation wait: up to $w s, from $((($(date +%s%3N) - th) / 1000)) s after heal"
  end=$((SECONDS + w))
  while :; do
    b=$(balance "$n"); k=0; [[ $b =~ ^[0-9]+$ ]] && k=$((b / amt))
    if ((k > kmax)); then kmax=$k; echo "[reorg] confirmed $k/$sent at $((($(date +%s%3N) - th) / 1000)) s after heal"; fi
    if [[ $b =~ ^[0-9]+$ ]] && ((b >= sent * amt)); then
      echo "[reorg] time to $sent/$sent after heal: $((($(date +%s%3N) - th) / 1000)) s (balance $b)"; return 0; fi
    ((SECONDS >= end)) && break; sleep 3
  done
  echo "[reorg] time to $sent/$sent after heal: not reached ($kmax/$sent by the end of the $w s wait; balance ${b:-0})"; return 1
}
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
wait fn reorg_confirmed D ${REORG_NANOERG:-100000000} ${REORG_CONFIRM_WAIT_S:-180} timeout 0
EOF
