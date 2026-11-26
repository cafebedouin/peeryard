# blockwatch: the per-block invariant monitor (rig/lib/blockwatch.sh, diag/block_invariants.py) on a small network
# with payments. A mines into its wallet; the monitor runs on A and B from the start; once the reward delay has passed,
# A pays B BLOCKWATCH_N (5) times, then mining goes on for BLOCKWATCH_S (60) s so the payments confirm and the pools
# are read after them. PASS = the monitor checked blocks on both nodes and found no violation (link, body, once, pool,
# agree, and any contract check in BLOCKWATCH_CONTRACTS), and B is on A's chain. A violation FAILs even when no payment
# was accepted; INCONCLUSIVE = no payment accepted, or the monitor checked no block (NO-INPUT).
# The designed failing control: BLOCKWATCH_CONTRACTS=rig/lib/invariants/deliberate-fail.sh must FAIL with cause
# BLOCK_INVARIANT (a contract check that fails on every block): it shows a violation is reported and reaches the verdict.
#   PEERYARD_JAR=~/ergo-6.0.6.jar bash rig/rig.sh rig/examples/blockwatch.json rig/examples/blockwatch.sh
N=${BLOCKWATCH_N:-5}; AMT=100000000; DUR=${BLOCKWATCH_S:-60}
blockwatch_start A B
sent=0
if wait_balance A $((AMT * N * 2)) 300 >/dev/null; then
  for _ in $(seq 1 "$N"); do id=$(pay A B "$AMT"); [[ "$id" =~ ^[0-9a-f]{64}$ ]] && sent=$((sent + 1)); sleep 0.5; done
fi
echo "[blockwatch] sent $sent/$N payments at A height $(full_height A)"
sleep "$DUR"
sc=$(same_chain A B); echo "[blockwatch] same_chain(A,B): $sc"
blockwatch_stop; echo "[blockwatch] result: $BLOCKWATCH_RESULT"
# a violation FAILs whether or not a payment went through (rig.sh adds the cause BLOCK_INVARIANT); a monitor that
# checked nothing (NO-INPUT) and a run with no accepted payment prove nothing either way
if [[ "$BLOCKWATCH_RESULT" == VIOLATED* ]]; then res=FAIL
elif [[ "$BLOCKWATCH_RESULT" != OK ]]; then res=INCONCLUSIVE; rig_cause=BLOCKWATCH_NO_INPUT; echo "[blockwatch] INCONCLUSIVE: the monitor checked no block (${BLOCKWATCH_RESULT:-no INVARIANTS line})"
elif (( sent == 0 )); then res=INCONCLUSIVE; rig_cause=NO_PAYMENT; echo "[blockwatch] INCONCLUSIVE: no payment was accepted, so the transaction checks saw none"
elif [[ "$sc" == SAME@* ]]; then res=PASS; else res=FAIL; fi
rig_verdict=$res
echo "[blockwatch] === BLOCKWATCH: $res ==="
