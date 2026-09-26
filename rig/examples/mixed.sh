# mixed: two node versions on one network. A runs PEERYARD_JAR (the topology's default) and mines; B runs
# PEERYARD_JAR_B (its own "jar") and follows. PASS = the two nodes report DIFFERENT appVersions (so two builds
# really took part; the same jar twice is a setup error, not a mixed network) and B fully syncs A's chain, at
# height >= 5, on the same header ids.
#   PEERYARD_JAR=~/ergo-6.0.6.jar PEERYARD_JAR_B=~/ergo-candidate.jar bash rig/rig.sh rig/examples/mixed.json rig/examples/mixed.sh
va=$(rest A /info | jq -r '.appVersion // "null"'); vb=$(rest B /info | jq -r '.appVersion // "null"')
echo "[mixed] A appVersion=$va  B appVersion=$vb"
echo "[mixed] A jar=$(basename "${NODE_JAR[A]}")  B jar=$(basename "${NODE_JAR[B]}")"
end=$((SECONDS+150)); res=FAIL; sc=""
while [ $SECONDS -lt $end ]; do
  bi=$(rest B /info); bf=$(echo "$bi" | jq -r '.fullHeight//0'); bh=$(echo "$bi" | jq -r '.headersHeight//0')
  sc=$(same_chain A B); echo "  A.full=$(full_height A)  B.full=$bf B.hdr=$bh  same_chain=$sc"
  case "$sc" in SAME@*) h=${sc#SAME@}; h=${h%%:*}; [ "$bf" = "$bh" ] && [ "${h:-0}" -ge 5 ] && { res=PASS; break; } ;; esac
  sleep 5
done
if [ "$va" = "$vb" ] || [ "$va" = null ] || [ "$vb" = null ]; then res=FAIL; echo "[mixed] FAIL: appVersions are not two distinct versions (A=$va B=$vb); check PEERYARD_JAR and PEERYARD_JAR_B"; fi
echo "[mixed] === MIXED VERDICT: $res (A=$va B=$vb $sc) ==="; rig_verdict=$res
echo "MIXED-DONE"
