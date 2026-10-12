# wallet-oracle-restart: does the subject's wallet come back from a lifecycle event with the same view as a reference
# wallet that holds the same keys and went through nothing (rig/WALLET-ORACLE.md)? M mines into the default test keys;
# S (subject) and R (reference) hold those keys with the mining switch on and an external miner nobody serves, so
# both wallets track M's rewards and neither mines; P holds other keys. Staging: matured rewards, three payments S -> P
# (spent boxes), three P -> S (received), then M stops and S sends one more payment that stays unconfirmed. Then the
# event, on S only (WO_EVENT):
#   restart      relaunch S (graceful stop and start)                     (default)
#   crash        crash S (SIGKILL), 5 s down, revive S
#   rescan       POST /wallet/rescan {"fromHeight": 0} on S
#   none         nothing: the A/A control, must PASS
#   rescan-from  POST /wallet/rescan {"fromHeight": <tip - 20>} on S: the positive control, must FAIL (S no longer sees
#                boxes below that height)
# Then M mines until the pending payment confirms and stops, and the oracle compares S and R at a settled point.
# WO_AT=pending compares instead right after the event, before any block, with the same-mempool rule dropped
# (WO_IGNORE_MEMPOOL): the wallet's unconfirmed view while the payment is still pending (what a wallet that persists
# its unconfirmed transactions keeps across a restart; on 6.0.6 a restart empties the pool). Either way:
# PASS = "[wallet-oracle] SAME@...", FAIL = "DIFF@...", INCONCLUSIVE = not settled, or a staging step that did not
# happen (keys differ, no rewards, the pending payment never reached both pools).
# shellcheck source=rig/lib/wallet_oracle.sh
source "$(dirname "$(readlink -f "$HOOK")")/../lib/wallet_oracle.sh"
EV="${WO_EVENT:-restart}"; AT="${WO_AT:-confirmed}"
label="$EV"; [[ "$AT" == pending ]] && label+=" at=pending"
wo_end(){ echo "[wo] versions $(wo_versions)"; echo "[wo] === WALLET-ORACLE-RESTART ($label): $rig_verdict ==="; echo "WALLET-ORACLE-DONE"; }
wo_inc(){ rig_verdict=INCONCLUSIVE; rig_cause="$1"; echo "[wallet-oracle] INCONCLUSIVE: $2"; wo_end; }
case "$EV" in none|restart|crash|rescan|rescan-from) ;; *) wo_inc BAD_EVENT "unknown WO_EVENT '$EV'"; return 0 ;; esac
case "$AT" in confirmed|pending) ;; *) wo_inc BAD_EVENT "unknown WO_AT '$AT'"; return 0 ;; esac
echo "[wo] event: $EV; jar $(basename "${NODE_JAR[S]:-?}")"

# precondition: one key derivation on both nodes (the same addresses), and P's keys are not theirs
if ! k=$(wallet_same_addresses S R); then wo_inc KEYS "precondition: $k"; return 0; fi
[[ "$(address P)" != "$(address S)" ]] || { wo_inc KEYS "precondition: P shares S's first address"; return 0; }
echo "[wo] precondition $k (S and R list the same addresses)"

wo_history S R P M || { wo_inc STAGING "$WO_WHY"; return 0; }
wo_stop_miner M S R P; wo_redial 60 M S R P
wo_same_tip 90 M S R P || { wo_inc STAGING "M, S, R, P not on one tip after M stopped"; return 0; }
wo_pending S R P || { wo_inc NO_PENDING "$WO_WHY"; return 0; }
h=$(full_height S); mark "wallet-oracle-event $EV"
echo "[wo] at the event: height $h, S balance $(balance S), S unspent $(wallet S '/wallet/boxes/unspent?minConfirmations=-1&limit=2500' | jq length)"
case "$EV" in
  restart) relaunch S || { wo_inc HARNESS "S did not come back after the relaunch"; return 0; } ;;
  crash) crash S; sleep 5; revive S || { wo_inc HARNESS "S did not come back after the revive"; return 0; } ;;
  rescan) echo "[wo] rescan: $(wallet S /wallet/rescan '{"fromHeight":0}')" ;;
  rescan-from) echo "[wo] rescan from $((h - 20)): $(wallet S /wallet/rescan "{\"fromHeight\":$((h - 20))}")" ;;
esac
echo "[wo] after the event: pending ${WO_PENDING:0:8} in S's pool: $(mempool_ids S | grep -qx "$WO_PENDING" && echo yes || echo no), in R's: $(mempool_ids R | grep -qx "$WO_PENDING" && echo yes || echo no)"
if [[ "$AT" == pending ]]; then
  WO_IGNORE_MEMPOOL=1 wallet_oracle S R 180
  echo "[wo] compared before any block: pending ${WO_PENDING:0:8} in S's pool: $(mempool_ids S | grep -qx "$WO_PENDING" && echo yes || echo no)"
  case "$WO_RESULT" in SAME) rig_verdict=PASS ;; DIFF) rig_verdict=FAIL; rig_cause=WALLET_DIFF ;; *) rig_verdict=INCONCLUSIVE; rig_cause=NOT_SETTLED ;; esac
  wo_end; return 0
fi
wo_confirm M 3 S R P || { wo_inc NOT_SETTLED "S, R and P did not reach M's tip after the confirming blocks"; return 0; }
echo "[wo] pending ${WO_PENDING:0:8} on R: inclusionHeight $(wallet R "/wallet/transactionById?id=$WO_PENDING" | jq -r '.inclusionHeight // "none"')"
wallet_oracle S R 180
case "$WO_RESULT" in SAME) rig_verdict=PASS ;; DIFF) rig_verdict=FAIL; rig_cause=WALLET_DIFF ;; *) rig_verdict=INCONCLUSIVE; rig_cause=NOT_SETTLED ;; esac
wo_end
