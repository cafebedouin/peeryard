# Positive control for the chain comparator (run it before trusting a "no divergence" result):
# two miners with knownPeers=[] never peer -> divergent chains -> comparator MUST
# report INEQUALITY. A comparator that reports SAME here is void.
# PASS = DIFF; FAIL = SAME (the comparator missed a real divergence). A comparison that could not be made is
# INCONCLUSIVE, not FAIL: NOHEIGHT (a node reported no full block: cause NO_HEIGHT) or NOID@... (a header id at the
# compared height was not read: cause NO_HEADER_ID); so is a peer list that could not be read (cause PEERS_UNREAD).
echo "[posctrl] two ISOLATED miners (no peering) -> chains must DIVERGE"
end=$((SECONDS+30))
while [ $SECONDS -lt $end ]; do
  ha=$(full_height A); hb=$(full_height B); echo "  A.h=$ha B.h=$hb"
  [ "${ha:-0}" -ge 3 ] && [ "${hb:-0}" -ge 3 ] && break; sleep 3
done
sc=$(same_chain A B); echo "  same_chain(A,B) => $sc"
# the premise: the two miners never peered (the topology turns the bring-up re-dial off)
# (a list's length, or nothing when the reply was not a JSON list: an unread list is not "no peers")
pa=$(rest A /peers/connected | jq -e 'if type == "array" then length else empty end' 2>/dev/null)
pb=$(rest B /peers/connected | jq -e 'if type == "array" then length else empty end' 2>/dev/null)
echo "  connected peers: A=${pa:-?} B=${pb:-?}"
if [ -z "$pa" ] || [ -z "$pb" ]; then
  echo "  OBSERVER-POSCTRL INCONCLUSIVE: a peer list was not read (A=${pa:-?} B=${pb:-?}); isolation is not shown"
  rig_verdict=INCONCLUSIVE; rig_cause=PEERS_UNREAD
elif [ "$pa" != 0 ] || [ "$pb" != 0 ]; then
  echo "  OBSERVER-POSCTRL INCONCLUSIVE: the miners peered (A=$pa B=$pb); the control needs them isolated"
  rig_verdict=INCONCLUSIVE; rig_cause=NOT_ISOLATED
else case "$sc" in
  DIFF@*) echo "  OBSERVER-POSCTRL PASS: comparator registered INEQUALITY (non-vacuous)"; rig_verdict=PASS;;
  SAME@*) echo "  OBSERVER-POSCTRL FAIL: expected DIFF, got '$sc'"; rig_verdict=FAIL;;
  NOHEIGHT) echo "  OBSERVER-POSCTRL INCONCLUSIVE: no full height to compare at ('$sc'); the comparator was not exercised"
          rig_verdict=INCONCLUSIVE; rig_cause=NO_HEIGHT;;
  NOID@*) echo "  OBSERVER-POSCTRL INCONCLUSIVE: a header id was not read ('$sc'); the comparator was not exercised"
          rig_verdict=INCONCLUSIVE; rig_cause=NO_HEADER_ID;;
  *)      echo "  OBSERVER-POSCTRL INCONCLUSIVE: same_chain printed '$sc', none of its tokens"; rig_verdict=INCONCLUSIVE; rig_cause=NO_TOKEN;;
esac; fi
echo "POSCTRL-DONE"
