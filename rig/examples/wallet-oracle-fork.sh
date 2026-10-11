# wallet-oracle-fork: does the subject's wallet come back from a fork switch with the same view as a reference wallet
# that never saw the losing fork (rig/WALLET-ORACLE.md)? Two miners hold the default test keys: M (with R and P on its
# side) and M2 (with S behind it). S and R hold those keys too, mining switch on with an external miner nobody serves,
# so both wallets track the miners' rewards and neither mines. Staging: matured rewards, S -> P and P -> S payments,
# all confirmed. Then the M - M2 link is cut: M2 mines a short fork that S follows, S pays P on it (confirmed there)
# and M2 stops; M mines to a lead of WO_LEAD (3) blocks and stops; S sends one more payment that stays unconfirmed.
# The heal makes S (and M2) roll back to M's heavier chain: the fork's rewards and the fork-confirmed payment must
# leave S's confirmed view, the payments return to the pool and confirm on M's chain, and then S must match R.
#   WO_FORK=0           no cut (the miners share one chain throughout): the A/A control, must PASS
#   WO_CONTROL=rescan-from  after the heal, rescan S from 20 blocks below its tip: the positive control, must FAIL
# PASS = "[wallet-oracle] SAME@...", FAIL = "DIFF@...", INCONCLUSIVE = not settled, no fork formed, M not heavier, or a
# staging step that did not happen. Needs netem (partition), so a host with sch_netem; WO_FORK=0 does not.
# shellcheck source=rig/lib/wallet_oracle.sh
source "$(dirname "$(readlink -f "$HOOK")")/../lib/wallet_oracle.sh"
FORK="${WO_FORK:-1}"; CTL="${WO_CONTROL:-}"; LEAD="${WO_LEAD:-3}"
label="fork=$FORK${CTL:+ control=$CTL}"
wo_end(){ echo "[wo] versions $(wo_versions)"; echo "[wo] === WALLET-ORACLE-FORK ($label): $rig_verdict ==="; echo "WALLET-ORACLE-DONE"; }
wo_inc(){ rig_verdict=INCONCLUSIVE; rig_cause="$1"; echo "[wallet-oracle] INCONCLUSIVE: $2"; wo_end; }
[[ "$FORK" == 0 || "$FORK" == 1 ]] || { wo_inc BAD_EVENT "WO_FORK must be 0 or 1, not '$FORK'"; return 0; }
[[ -z "$CTL" || "$CTL" == rescan-from ]] || { wo_inc BAD_EVENT "unknown WO_CONTROL '$CTL'"; return 0; }
wait_h(){ local n="$1" min="$2" end=$((SECONDS + ${3:-120})); while [[ $SECONDS -lt $end ]]; do [[ "$(full_height "$n")" -ge "$min" ]] 2>/dev/null && return 0; sleep 2; done; return 1; }
tx_height(){ wallet "$1" "/wallet/transactionById?id=$2" | jq -r '.inclusionHeight // "none"' 2>/dev/null; }
echo "[wo] $label; jar $(basename "${NODE_JAR[S]:-?}")"

if ! k=$(wallet_same_addresses S R); then wo_inc KEYS "precondition: $k"; return 0; fi
[[ "$(address P)" != "$(address S)" ]] || { wo_inc KEYS "precondition: P shares S's first address"; return 0; }
echo "[wo] precondition $k (S and R list the same addresses)"

wo_history S R P M || { wo_inc STAGING "$WO_WHY"; return 0; }
stop_mining M >/dev/null; settle_height_back M; wo_redial 60 M R P M2
wo_same_tip 120 M S R P M2 || { wo_inc STAGING "the five nodes are not on one tip after M stopped"; return 0; }
h0=$(full_height M); echo "[wo] shared tip at $h0"

[[ "$FORK" == 1 ]] && { partition M M2 || { wo_inc HARNESS "partition M M2 failed"; return 0; }; }
mark "wallet-oracle-fork start"
start_mining M2 3s >/dev/null; settle_height_back M2; wo_redial 60 M2 S
[[ "$FORK" == 0 ]] && wo_redial 60 M M2
# S pays P on its side (on the fork when cut): P is out of reach then, so the payment travels S -> M2 only
sleep 2; fid=$(pay S P 400000000)
[[ "$fid" =~ ^[0-9a-f]{64}$ ]] || { wo_inc STAGING "S's payment on its side was rejected: $fid"; return 0; }
end=$((SECONDS + 120)); while [[ $SECONDS -lt $end ]]; do [[ "$(tx_height S "$fid")" =~ ^[0-9]+$ ]] && break; sleep 2; done
fh=$(tx_height S "$fid"); [[ "$fh" =~ ^[0-9]+$ ]] || { wo_inc STAGING "S's payment ${fid:0:8} never confirmed on S's side"; return 0; }
wait_h M2 $((h0 + 3)) 120
h2=$(full_height M2); stop_mining M2 >/dev/null; settle_height_back M2; wait_h M2 "$h2" 60; wo_redial 60 M2 S
h2=$(full_height M2); echo "[wo] S's side: payment ${fid:0:8} confirmed at $fh; M2 stopped at $h2"
# with no cut, M must hold M2's blocks before it mines: else it builds a competing branch from where it stopped and the
# "no event" control holds a reorg after all (seen once: S rolled back three blocks)
if [[ "$FORK" == 0 ]]; then wo_redial 60 M M2; wo_same_tip 90 M2 M R P || { wo_inc STAGING "M did not reach M2's tip before mining (no cut)"; return 0; }; fi
start_mining M 1500ms >/dev/null; settle_height_back M; wo_redial 60 M R P
[[ "$FORK" == 0 ]] && wo_redial 60 M M2
wait_h M $((h2 + LEAD)) 180
h1=$(full_height M); stop_mining M >/dev/null; settle_height_back M; wait_h M "$h1" 60; wo_redial 60 M R P
[[ "$FORK" == 0 ]] && wo_redial 60 M M2
h1=$(full_height M); echo "[wo] M stopped at $h1"
wo_same_tip 90 M2 S || { wo_inc STAGING "S is not on M2's tip before the heal"; return 0; }
sc=$(same_chain M S); echo "[wo] before the heal: same_chain(M,S) $sc"
if [[ "$FORK" == 1 ]]; then
  [[ "${sc%%@*}" == DIFF ]] || { wo_inc NO_FORK "M and S are not on different chains before the heal ($sc)"; return 0; }
  [[ "$h1" -gt "$h2" ]] || { wo_inc NOT_HEAVIER "M ($h1) is not ahead of M2 ($h2)"; return 0; }
fi
wo_pending S M2 P || { wo_inc NO_PENDING "$WO_WHY"; return 0; }
s_fork_boxes=$(wallet S '/wallet/boxes/unspent?minConfirmations=0&minInclusionHeight='$((h0 + 1))'&limit=2500' | jq length)
echo "[wo] at the heal: S at $(full_height S), $s_fork_boxes of S's unspent boxes above the shared tip $h0"
mark "wallet-oracle-fork heal"
[[ "$FORK" == 1 ]] && { heal M M2 || { wo_inc HARNESS "heal M M2 failed"; return 0; }; }
wo_redial 60 M M2
wo_confirm M 3 S R P M2 || { wo_inc NOT_SETTLED "S, R, P and M2 did not reach M's tip after the heal"; return 0; }
echo "[wo] after the heal: same_chain(M,S) $(same_chain M S); S at $(full_height S); S's fork payment ${fid:0:8} now at $(tx_height S "$fid") on S, $(tx_height R "$fid") on R; pending ${WO_PENDING:0:8} at $(tx_height R "$WO_PENDING") on R"
if [[ "$CTL" == rescan-from ]]; then h=$(full_height S); echo "[wo] control: rescan S from $((h - 20)): $(wallet S /wallet/rescan "{\"fromHeight\":$((h - 20))}")"; fi
rb=$(grep -c 'Rollback UtxoState' "$RIG_LOG_DIR/node_S.log" 2>/dev/null); echo "[wo] S's state rollbacks in its log: ${rb:-?}"
if [[ "$FORK" == 0 && "${rb:-0}" != 0 ]]; then wo_inc STAGING "the no-cut control saw $rb rollback(s) on S; it is not a no-event run"; return 0; fi
wallet_oracle S R 240
case "$WO_RESULT" in SAME) rig_verdict=PASS ;; DIFF) rig_verdict=FAIL; rig_cause=WALLET_DIFF ;; *) rig_verdict=INCONCLUSIVE; rig_cause=NOT_SETTLED ;; esac
wo_end
