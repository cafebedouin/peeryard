# bring-up self-test hook (sourced by rig.sh inside the namespace).
# Validates: (1) A mines, (2) B connects to A over the veth and syncs,
# (3) the cross-node header-id observer with its POSITIVE CONTROL
#     (pre-sync tips DIFFER -> observer reports INEQUALITY; post-sync B is on A's chain).
# B follows a live miner, so its tip is always a little behind A's: the sync check is `same_chain`, which
# compares header ids at the lower of the two heights, never tip equality (a miner is always ahead).
echo "[bringup] initial tips (positive control: expect INEQUALITY while B is unsynced)"
hA0="$(applied_header A)"; hB0="$(applied_header B)"
echo "  A=$hA0  B=$hB0"
if [[ "$hA0" != "$hB0" ]]; then echo "  OBSERVER-POSCTRL: INEQUALITY registered OK"; else echo "  (tips already equal; will re-check after mining)"; fi

echo "[bringup] letting A mine + B sync (up to 90s)"
end=$((SECONDS+90)); sc=""
while [[ $SECONDS -lt $end ]]; do
  hA="$(full_height A)"; hB="$(full_height B)"
  conn="$(rest B /peers/connected | jq -r 'length' 2>/dev/null)"
  sc="$(same_chain A B)"
  echo "  A.h=$hA B.h=$hB B.connected=$conn same_chain=${sc%%:*}"
  case "$sc" in SAME@*) h=${sc#SAME@}; h=${h%%:*}; [[ "${h:-0}" -ge 3 ]] && break ;; esac
  sleep 4
done

echo "[bringup] final observer check: same_chain(A,B) => ${sc%%:*}"
case "$sc" in
  SAME@*) h=${sc#SAME@}; h=${h%%:*}
          if [[ "${h:-0}" -ge 3 ]]; then echo "  SYNC-OK: B is on A's chain at height $h (B.h=$(full_height B), A.h=$(full_height A), A keeps mining)"; rig_verdict=PASS
          else echo "  NOT-CONVERGED: same chain only up to height $h"; rig_verdict=FAIL; fi ;;
  *)      echo "  NOT-CONVERGED ($sc)"; rig_verdict=FAIL ;;
esac
echo "[bringup] B connected peers:"; rest B /peers/connected | jq -r '.[]?|.address+" "+(.name//"")' 2>/dev/null
echo "[bringup] state roots (SAME@h when heights are equal, LAG while B catches up): $(same_state A B | cut -c1-40)"
echo "[bringup] peers vs topology:"; check_topology || { echo "  topology check FAILED"; rig_verdict=FAIL; }
echo "[bringup] netem knob check: add 40ms A<->B, confirm live change applies"
if link_netem A B "delay 40ms"; then echo "  netem A->B set to 40ms (rig knob works)"
else echo "  netem A->B FAILED: is sch_netem loaded? (sudo modprobe sch_netem)"; rig_verdict=FAIL; fi
echo "BRINGUP-DONE"
