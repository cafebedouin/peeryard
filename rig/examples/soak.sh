# soak: a long run whose length is the question's, not the script's. A mines at a fixed block-interval target
# (chain preset "current": 2 s), B follows. Every minute the block rate and the chain agreement are recorded;
# optionally B is crashed and revived every SOAK_CRASH_EVERY_MIN minutes and must catch up each time.
#   PEERYARD_DURATION   seconds to run (default 600)
#   SOAK_CRASH_EVERY_MIN crash/revive B every N minutes (default 0 = never)
#   SOAK_RATE_TARGET     expected blocks/min after retargeting (default 30 for a 2 s interval)
# PASS = the chain passed height 128 (the devnet's version2ActivationHeight, where the difficulty is reset once;
# retargets happen every 16 blocks before and after it), B is on A's chain at the end, the mean rate over the
# last three minutes is within a factor of two of the target, and every revive caught up. "On A's chain": same_chain
# SAME and same_state either SAME@h or LAG@.. same-chain (behind on the same chain is acceptable: A never stops
# mining). A LAG@.. fork, a DIFF root, or a state that stays unreadable ("unknown") fails.
DUR=${PEERYARD_DURATION:-600}; EVERY=${SOAK_CRASH_EVERY_MIN:-0}; TARGET=${SOAK_RATE_TARGET:-30}
echo "[soak] duration ${DUR}s, crash/revive every ${EVERY} min (0 = never), rate target ${TARGET}/min; chain: $(grep -h -E 'blockInterval|minerRewardDelay' "$SCRATCH"/conf_A.conf | tr '\n' ' ')"
t0=$SECONDS; minute=0; h_prev=$(full_height A); rates=""; revives=0; revive_fail=0; orphans=0
while [ $((SECONDS - t0)) -lt "$DUR" ]; do
  sleep 60; minute=$((minute + 1)); h=$(full_height A); r=$((h - h_prev)); rates="$rates $r"
  orph=$(orphans_between A $((h_prev + 1)) "$h"); orphans=$((orphans + orph)); h_prev=$h
  echo "  t+$((SECONDS - t0))s A.h=$h (+$r/min, orphans $orph) B.h=$(full_height B) same_chain=$(same_chain A B | cut -c1-12) same_state=$(same_state A B | cut -d: -f1) difficulty=$(rest A /info | jq -r '.difficulty // "?"') rss_mb A=$(rss_mb A) B=$(rss_mb B) data_mb A=$(data_mb A) B=$(data_mb B)"
  if [ "$EVERY" -gt 0 ] && [ $((minute % EVERY)) -eq 0 ]; then
    pre=$(full_height B); crash B; sleep 5; revive B; revives=$((revives + 1))
    end=$((SECONDS + 120)); ok=no
    while [ $SECONDS -lt $end ]; do bf=$(full_height B); af=$(full_height A); [ "${bf:-0}" -ge "$pre" ] && [ $((af - bf)) -le 5 ] && { ok=yes; break; }; sleep 3; done
    echo "  revive #$revives: B $pre -> $(full_height B) (A $(full_height A)) caught up: $ok"; [ $ok = yes ] || revive_fail=$((revive_fail + 1))
  fi
done
final=$(full_height A); sc=$(same_chain A B); st=$(same_state A B)
# an unreadable id ("LAG@.. unknown") is not a verdict: re-sample for up to 30 s
end=$((SECONDS + 30)); while [ $SECONDS -lt $end ]; do case "$st" in LAG@*" unknown") sleep 2; st=$(same_state A B) ;; *) break ;; esac; done
post=$(echo "$rates" | awk '{ n=0; s=0; for (i=NF-2; i<=NF; i++) if (i>0) { s+=$i; n++ } print (n>0 ? s/n : 0) }')
rate_ok=$(awk -v p="$post" -v t="$TARGET" 'BEGIN { print (p >= t/2 && p <= t*2) ? "yes" : "no" }')
echo "[soak] final A.h=$final; per-minute:$rates; mean of last 3 min: $post/min (target $TARGET, ok: $rate_ok); orphans over the run: $orphans; same_chain: ${sc%%:*}; same_state: ${st%%:*}; revives $revives (failed $revive_fail); rss_mb A=$(rss_mb A) B=$(rss_mb B); data_mb A=$(data_mb A) B=$(data_mb B)"
echo "[soak] peers vs topology:"; check_topology || echo "[soak] (peer check reported a mismatch)"
res=FAIL
case "$st" in SAME@*) st_ok=yes ;; LAG@*" same-chain") st_ok=lag ;; *) st_ok=no ;; esac
if [ "$final" -gt 128 ] && [ "${sc%%@*}" = SAME ] && [ "$st_ok" != no ] && [ "$rate_ok" = yes ] && [ "$revive_fail" = 0 ]; then res=PASS; fi
echo "[soak] === SOAK: $res ==="; rig_verdict=$res
echo "SOAK-DONE"
