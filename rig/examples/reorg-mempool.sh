# reorg-mempool: transactions confirmed on the losing side of a fork must survive the reorg. The miner that funds
# the payments (C) is the one whose fork loses, so its spent inputs are still unspent on the winning chain.
# Staging (deterministic; a node whose header height is ahead of its full-block height refuses to mine — "waiting
# for sync" — so the winner is fully synced before it is isolated, and the two miners never race for the win):
#   floor   - C mines the shared chain and matures its wallet; A and D follow.
#   settle  - C's mining is paused and A, D fully sync to C's tip (full height == header height, no gap), so A
#             can mine once isolated.
#   split   - the A-C link is cut. A mines its own fork from the shared tip; C resumes, mines a few blocks and
#             pays D N times (they confirm on C's fork, D sees them), then C is frozen. A keeps mining to a small
#             lead over C's frozen tip, then A is frozen too — a small, stationary winning fork.
#   heal    - the link is restored and A is relaunched to re-dial C on the healed link, then mines slowly to
#             confirm the payments the reorg returns to the mempool. C's payments were spent from rewards matured
#             before the split (shared prefix), so their inputs are unspent on A's chain and can be re-admitted.
# PASS = A strictly heavier at heal, C and D reorganise onto A's chain and state, and D's confirmed balance still
# covers every accepted payment. INCONCLUSIVE = A's lead at the heal reached REORG_MAX_LEAD (default 15) blocks.
# Env: REORG_TXS (default 10), REORG_NANOERG (0.1 ERG), REORG_MAX_LEAD (15).
N=${REORG_TXS:-10}; AMT=${REORG_NANOERG:-100000000}; fail=0
need=$((AMT * N + 200000000))
# full_height reads 0 for a few seconds after a (re)launch while the node reloads its chain, so read a height
# only through wait_h. hdr_height is the node's best-header height; a node is fully synced when they are equal.
wait_h(){ local n="$1" min="$2" end=$((SECONDS + ${3:-90})); while [ $SECONDS -lt $end ]; do [ "$(full_height "$n")" -ge "$min" ] 2>/dev/null && { full_height "$n"; return 0; }; sleep 2; done; full_height "$n"; return 1; }
hdr_height(){ rest "$1" /info | jq -r '.headersHeight // 0'; }
full_synced(){ local n="$1" h; h=$(full_height "$n"); [ "${h:-0}" -ge 1 ] && [ "$h" = "$(hdr_height "$n")" ]; }

echo "[reorg] floor: C mines the shared chain; A and D follow; C matures >= $need nanoERG"
end=$((SECONDS + 240)); ok=no
while [ $SECONDS -lt $end ]; do
  cb=$(balance C)
  if [ "$(same_chain C A | cut -c1-4)" = SAME ] && [ "$(same_chain C D | cut -c1-4)" = SAME ] \
     && [ "${cb:-0}" -ge "$need" ] 2>/dev/null && [ "$(full_height C)" -ge 12 ]; then ok=yes; break; fi
  sleep 3
done
[ $ok = yes ] || { echo "[reorg] FAIL: floor not reached (C.balance=$(balance C) heights A=$(full_height A) C=$(full_height C) D=$(full_height D))"; fail=1; }

if [ $fail = 0 ]; then
  echo "[reorg] settle: pause C, let A and D fully sync (full height == header height) so A can mine when isolated"
  hpre=$(full_height C)         # C's height before pausing (read it before the relaunch resets it to 0)
  stop_mining C
  hshared=$(wait_h C "$hpre")
  end=$((SECONDS + 120)); ok=no
  while [ $SECONDS -lt $end ]; do
    if [ "$(full_height A)" -ge "$hshared" ] && [ "$(full_height D)" -ge "$hshared" ] && full_synced A && full_synced D; then ok=yes; break; fi
    sleep 3
  done
  echo "[reorg] settled=$ok at shared height $hshared (A full=$(full_height A)/hdr=$(hdr_height A), D full=$(full_height D)/hdr=$(hdr_height D))"
  [ $ok = yes ] || fail=1
fi

if [ $fail = 0 ]; then
  h0="$hshared"
  echo "[reorg] cut A<->C at height $h0; A mines its fork, C mines briefly and pays D from shared-prefix rewards"
  partition A C
  # A mines its fork slowly: stopping a miner relaunches the node, and at a fast rate A overshoots by ~30 blocks while
  # it stops, which turns this into a different test (a switch taken while far behind the header chain). The lead
  # is kept small and checked below.
  start_mining A 3s; wait_h A "$h0" >/dev/null
  start_mining C 1500ms; wait_h C "$h0" >/dev/null
  # Send the whole burst fast, right as C resumes: at height h0 only shared-prefix rewards are matured, and the
  # inputs are chosen at payment-creation time, so paying before C mines fork blocks whose rewards mature keeps
  # every payment spending a shared-prefix box (whose input survives on A's chain). An inter-payment pause would
  # let fork rewards mature and be spent, and those payments could not be re-confirmed after the reorg.
  sleep 2
  sent=0
  for i in $(seq 1 "$N"); do
    id=$(pay C D "$AMT"); if [[ "$id" =~ ^[0-9a-f]{64}$ ]]; then sent=$((sent + 1)); else echo "  pay $i rejected: $id"; fi; sleep 0.15
  done
  echo "[reorg] C sent $sent/$N payments on its fork"
  # the claim is about payments confirmed on the losing side: without them there is nothing to lose in the reorg
  inconclusive(){ echo "[reorg] INCONCLUSIVE: $2"; rig_verdict=INCONCLUSIVE; rig_cause=$1; echo "[reorg] === REORG-MEMPOOL: $rig_verdict ==="; echo "REORG-DONE"; }
  if [ "$sent" -lt 1 ]; then inconclusive NO_PAYMENTS "C sent no payment on its fork"; return 0; fi
  if ! bd=$(wait_balance D $((AMT * sent)) 120); then
    inconclusive NOT_CONFIRMED_ON_FORK "D did not confirm C's payments on C's fork ($bd of $((AMT * sent)))"; return 0; fi
  echo "[reorg] on C's fork: D confirmed $bd nanoERG (sent $sent)"

  hc=$(full_height C); stop_mining C; hc=$(wait_h C "$hc"); depth=$((hc - h0))
  echo "[reorg] C frozen at height $hc (fork depth $depth); A mines to a small lead, then is frozen"
  end=$((SECONDS + 180)); ha=0
  while [ $SECONDS -lt $end ]; do ha=$(full_height A); [ "${ha:-0}" -ge $((hc + 3)) ] && break; sleep 2; done
  stop_mining A; ha=$(wait_h A "$((hc + 3))")
  echo "[reorg] A ahead at $ha vs C $hc (small fork)"
  if [ "${ha:-0}" -le "$hc" ]; then echo "[reorg] FAIL: A ($ha) never overtook C ($hc)"; fail=1; fi
  if [ $fail = 0 ] && [ $((ha - hc)) -ge ${REORG_MAX_LEAD:-15} ]; then
    echo "[reorg] INCONCLUSIVE: A's lead $((ha - hc)) >= ${REORG_MAX_LEAD:-15} blocks (staging overshoot; this example tests an ordinary reorg)"
    rig_verdict=INCONCLUSIVE; rig_cause=STAGING_OVERSHOOT; echo "[reorg] === REORG-MEMPOOL: $rig_verdict ==="; echo "REORG-DONE"; return 0
  fi

  # a reorg needs two chains: A and C must disagree at their common height before the heal
  sc=$(same_chain A C)
  if [ "${sc%%@*}" != DIFF ]; then inconclusive NO_FORK "A and C are not on different chains before the heal ($sc)"; return 0; fi
  echo "[reorg] fork before heal: $sc"
  echo "[reorg] heal A<->C, relaunch A to re-dial C on the healed link and confirm the re-admitted payments"
  heal A C; t0=$SECONDS
  start_mining A 3s
  end=$((SECONDS + 200)); ok=no
  while [ $SECONDS -lt $end ]; do
    ah=$(full_height A)
    # C's state: SAME@h, or behind on A's chain (LAG@.. same-chain); DIFF@ and LAG@.. fork/unknown do not count
    stc=$(same_state A C)
    if [ "$(same_chain A C | cut -c1-4)" = SAME ] && { [ "${stc%%@*}" = SAME ] || [ "${stc##* }" = same-chain ]; } && [ "$(same_chain A D | cut -c1-4)" = SAME ] \
       && [ "${ah:-0}" -ge "$ha" ] && [ $((ah - $(full_height C))) -le 5 ] && [ $((ah - $(full_height D))) -le 5 ] 2>/dev/null; then ok=yes; break; fi
    sleep 4
  done
  echo "[reorg] C and D reorged onto A's chain and state: $ok ($((SECONDS - t0)) s); A=$(full_height A) C=$(full_height C) D=$(full_height D)"
  [ $ok = yes ] || fail=1

  bd2=$(wait_balance D $((AMT * sent)) 180)
  echo "[reorg] D confirmed balance on the surviving chain: $bd2 (expected >= $((AMT * sent))), $((SECONDS - t0)) s after heal"
  [ "${bd2:-0}" -ge $((AMT * sent)) ] || { echo "[reorg] FAIL: payments lost in the reorg"; fail=1; }
  echo "[reorg] reorg depth $depth blocks; A was heavier: $([ "${ha:-0}" -gt "$hc" ] && echo yes || echo no); payments re-confirmed: $([ "${bd2:-0}" -ge $((AMT * sent)) ] && echo yes || echo no)"
fi
if [ $fail = 0 ]; then rig_verdict=PASS; else rig_verdict=FAIL; fi
echo "[reorg] === REORG-MEMPOOL: $rig_verdict ==="; echo "REORG-DONE"
