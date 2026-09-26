# Positive control for the chain comparator (run it before trusting a "no divergence" result):
# two miners with knownPeers=[] never peer -> divergent chains -> comparator MUST
# report INEQUALITY. A comparator that reports SAME here is void.
echo "[posctrl] two ISOLATED miners (no peering) -> chains must DIVERGE"
end=$((SECONDS+30))
while [ $SECONDS -lt $end ]; do
  ha=$(full_height A); hb=$(full_height B); echo "  A.h=$ha B.h=$hb"
  [ "${ha:-0}" -ge 3 ] && [ "${hb:-0}" -ge 3 ] && break; sleep 3
done
sc=$(same_chain A B); echo "  same_chain(A,B) => $sc"
# the premise: the two miners never peered (the topology turns the bring-up re-dial off)
pa=$(rest A /peers/connected | jq 'length' 2>/dev/null); pb=$(rest B /peers/connected | jq 'length' 2>/dev/null)
echo "  connected peers: A=${pa:-?} B=${pb:-?}"
if [ "${pa:-1}" != 0 ] || [ "${pb:-1}" != 0 ]; then
  echo "  OBSERVER-POSCTRL INCONCLUSIVE: the miners peered (A=${pa:-?} B=${pb:-?}); the control needs them isolated"
  rig_verdict=INCONCLUSIVE; rig_cause=NOT_ISOLATED
else case "$sc" in
  DIFF@*) echo "  OBSERVER-POSCTRL PASS: comparator registered INEQUALITY (non-vacuous)"; rig_verdict=PASS;;
  *)      echo "  OBSERVER-POSCTRL FAIL: expected DIFF, got '$sc'"; rig_verdict=FAIL;;
esac; fi
echo "POSCTRL-DONE"
