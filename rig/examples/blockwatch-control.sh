# blockwatch-control: the per-block monitor's designed failing check. The `blockwatch` example with the contract check
# rig/lib/invariants/deliberate-fail.sh added, which fails on every block. PASS = the monitor reports that check as
# violated on every block it checked (contract:deliberate-fail.sh = the number of distinct blocks on the final chains)
# and the generic checks as before (none violated), and blockwatch_stop returns the violation: a violation is reported,
# with its node, height and reason, and would turn a run's PASS into FAIL. This run's own violation is the expected one,
# so the rig is told not to judge it (PEERYARD_BLOCKWATCH_JUDGE=0); `BLOCKWATCH_CONTRACTS=rig/lib/invariants/deliberate-fail.sh`
# on the `blockwatch` example shows the judged path (that run must FAIL with cause BLOCK_INVARIANT).
#   PEERYARD_JAR=~/ergo-6.0.6.jar bash rig/rig.sh rig/examples/blockwatch-control.json rig/examples/blockwatch-control.sh
BLOCKWATCH_S=${BLOCKWATCH_S:-30}
blockwatch_start A B
wait_balance A 1 120 >/dev/null; sleep "$BLOCKWATCH_S"
bw_rc=0; blockwatch_stop --contract "$(dirname "$(readlink -f "$HOOK")")/../lib/invariants/deliberate-fail.sh" || bw_rc=$?
PEERYARD_BLOCKWATCH_JUDGE=0   # read by rig.sh after the hook: the violation above is this control's expected outcome
inv="$RIG_LOG_DIR/invariants.json"
blocks=$(jq -r '.blocks // 0' "$inv" 2>/dev/null); dfail=$(jq -r '.violations["contract:deliberate-fail.sh"] | length' "$inv" 2>/dev/null)
others=$(jq -r '[.violations | to_entries[] | select(.key != "contract:deliberate-fail.sh") | .value | length] | add // 0' "$inv" 2>/dev/null)
echo "[blockwatch-control] blockwatch_stop returned $bw_rc; distinct blocks $blocks; deliberate-fail violations $dfail; other violations $others"
res=FAIL
[[ $bw_rc == 1 && "${blocks:-0}" -ge 5 && "$dfail" == "$blocks" && "$others" == 0 ]] && res=PASS
[[ "${blocks:-0}" -lt 5 ]] && { res=INCONCLUSIVE; rig_cause=TOO_FEW_BLOCKS; }
rig_verdict=$res
echo "[blockwatch-control] === BLOCKWATCH-CONTROL: $res ==="
