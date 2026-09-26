# arkadianet-follow: a second implementation as a follower. A is the JVM reference node (PEERYARD_JAR) mining on
# the rust-devnet chain preset (the private devnet compiled into the Rust nodes); B is the arkadianet/ergo node binary (v0.8.0 or later, `network = "devnet"`),
# launched by the rig with "kind": "arkadianet" and $PEERYARD_ARKADIANET_BIN, dialling A. The rig's oracles are the
# same REST paths for both kinds: /info (fullHeight, headersHeight, bestFullHeaderId, stateRoot, appVersion,
# name), /blocks/at/{h} and /peers/connected (name). A mines until height 40 while B follows (its header ids
# are compared every 5 s); A then stops mining so B can settle at A's height, and the state roots are compared
# at that equal height (a follower that syncs in batches never sits level with a live miner).
#   PEERYARD_JAR=~/ergo-6.0.6.jar PEERYARD_ARKADIANET_BIN=<binary> bash rig/rig.sh rig/examples/arkadianet-follow.json rig/examples/arkadianet-follow.sh
# PASS = the two nodes report different appVersions (a JVM and a Rust build really took part), B was on A's
# chain by header id while A mined, B settles at A's height (>= 30) with full height equal to header height and
# the same UTXO state root, and the peer sets match the topology (each side lists the other by name).
va=$(rest A /info | jq -r '.appVersion // "null"'); vb=$(rest B /info | jq -r '.appVersion // "null"')
echo "[arkadianet-follow] A (jvm) appVersion=$va jar=$(basename "${NODE_JAR[A]}")  B (arkadianet) appVersion=$vb bin=$(basename "${NODE_JAR[B]}") network=$(rest B /info | jq -r '.network // "?"')"
echo "[arkadianet-follow] B /info at start: $(rest B /info | jq -c '{name, appVersion, network, fullHeight, headersHeight, peersCount}' 2>/dev/null)"
end=$((SECONDS + 240)); sc=""; followed=no; maxlag=0
while [ $SECONDS -lt $end ]; do
  bi=$(rest B /info); bf=$(jq -r '.fullHeight // 0' <<< "$bi"); bh=$(jq -r '.headersHeight // 0' <<< "$bi"); af=$(full_height A)
  sc=$(same_chain A B); lag=$((af - bf)); [ $lag -gt $maxlag ] && maxlag=$lag
  echo "  A.full=$af  B.full=$bf B.hdr=$bh peers=$(jq -r '.peersCount // "?"' <<< "$bi")  same_chain=${sc:0:14}"
  case "$sc" in SAME@*) h=${sc#SAME@}; h=${h%%:*}; [ "${h:-0}" -ge 10 ] && followed=yes ;; DIFF@*) followed=DIFF ;; esac
  [ "${af:-0}" -ge 40 ] && [ $followed != no ] && break; sleep 5
done
echo "[arkadianet-follow] while A mined: B followed by header id: $followed (largest lag seen $maxlag blocks); stopping A's miner so B can settle"
stop_mining A
end=$((SECONDS + 150)); st=""; res=FAIL
while [ $SECONDS -lt $end ]; do
  bi=$(rest B /info); bf=$(jq -r '.fullHeight // 0' <<< "$bi"); bh=$(jq -r '.headersHeight // 0' <<< "$bi"); st=$(same_state A B); sc=$(same_chain A B)
  echo "  settle: A.full=$(full_height A) B.full=$bf B.hdr=$bh same_chain=${sc:0:14} same_state=${st%%:*}"
  case "$st" in SAME@*) h=${st#SAME@}; h=${h%%:*}; [ "$bf" = "$bh" ] && [ "${h:-0}" -ge 30 ] && { res=PASS; break; } ;; DIFF@*) break ;; esac
  sleep 5
done
echo "[arkadianet-follow] B /blocks/at/1: $(rest B /blocks/at/1 | jq -c . 2>/dev/null)  A /blocks/at/1: $(rest A /blocks/at/1 | jq -c .)"
echo "[arkadianet-follow] peers vs topology:"; check_topology && topo=ok || topo=mismatch
echo "[arkadianet-follow] A sees: $(rest A /peers/connected | jq -c '[.[] | {name, address, connectionType}]')"
echo "[arkadianet-follow] B sees: $(rest B /peers/connected | jq -c '[.[] | {name, address, connectionType}]')"
[ "$topo" = ok ] || res=FAIL; [ $followed = yes ] || res=FAIL
if [ "$va" = "$vb" ] || [ "$va" = null ] || [ "$vb" = null ]; then res=FAIL; echo "[arkadianet-follow] FAIL: appVersions are not two distinct versions (A=$va B=$vb)"; fi
echo "[arkadianet-follow] === ARKADIANET-FOLLOW: $res (A=$va B=$vb followed=$followed maxlag=$maxlag ${sc%%:*} ${st%%:*} topology=$topo) ==="; rig_verdict=$res
echo "ARKADIANET-FOLLOW-DONE"
