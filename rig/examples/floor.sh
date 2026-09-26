# floor: check that the devnet behaves like a real chain before trusting any experiment built on it.
# An induced failure only means something if the undisturbed network normally works.
echo "[floor] network magic in the generated conf: $(grep -h magicBytes "$SCRATCH"/conf_A.conf 2>/dev/null)"
# TEST 1: a sole-peer follower fully syncs. PASS = B.fullHeight == B.headersHeight >= 5.
echo "[floor] TEST 1: sole-peer full-sync"
end=$((SECONDS+120)); sync=FAIL; bf=0; bh=0
while [ $SECONDS -lt $end ]; do
  bi=$(rest B /info); bf=$(echo "$bi"|jq -r '.fullHeight//0'); bh=$(echo "$bi"|jq -r '.headersHeight//0')
  af=$(full_height A); conn=$(rest B /peers/connected|jq -r 'length' 2>/dev/null)
  echo "  A.full=$af  B.full=$bf B.hdr=$bh  B.connected=$conn"
  if [ "${bf:-0}" -ge 5 ] && [ "$bf" = "$bh" ]; then sync=PASS; break; fi
  sleep 5
done
echo "[floor] TEST 1 sole-peer full-sync = $sync (B.full=$bf B.hdr=$bh)"
# TEST 2: the chain survives a restart.
hb=$(full_height A); echo "[floor] TEST 2: restart-persistence; A.full before=$hb"
stop_mining A
persist=FAIL
for i in $(seq 1 20); do h=$(rest A /info|jq -r '.fullHeight // "null"'); echo "  +$((i*3))s A.full=$h"
  if [ "$h" != "null" ] && [ "${h:-0}" -ge "$hb" ] 2>/dev/null; then persist=PASS; break; fi; sleep 3; done
echo "[floor] TEST 2 restart-persistence = $persist (before=$hb after=$(rest A /info|jq -r '.fullHeight // "null"'))"
echo "[floor] === FLOOR VERDICT: full-sync=$sync persist=$persist ==="
if [ "$sync" = PASS ] && [ "$persist" = PASS ]; then echo "[floor] FLOOR HOLDS"; rig_verdict=PASS; else echo "[floor] FLOOR BROKEN: fix the devnet setup before trusting other experiments"; rig_verdict=FAIL; fi
echo "FLOOR-DONE"
