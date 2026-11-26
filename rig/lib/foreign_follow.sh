# rig/lib/foreign_follow.sh: the body of the follow examples for another implementation (arkadianet-follow,
# ergo-node-rust-follow and their -magic variants). Sourced by those hooks, which keep their own header and usage line.
#
#   foreign_follow <label> <kind>
#
# A is the JVM reference node mining on the rust-devnet preset; B is the <kind> node following it. <label> names the
# example in its output: lines start "[<label>]", and the verdict line is "=== <LABEL>: <PASS|FAIL> (...) ===" (the label
# upper-cased, the suite.tsv marker), then "<LABEL>-DONE". A mines until height 40 while B follows (header ids compared
# every 5 s); A then stops mining so B can settle at A's height, and the state roots are compared at that equal height.
# PASS = different appVersions, B on A's chain by header id while A mined, B settled at A's height (>= 30) with full
# height equal to header height and the same UTXO state root, and the peer sets match the topology. Sets rig_verdict.
foreign_follow(){ local label="$1" kind="$2" up va vb end sc="" st="" followed=no maxlag=0 bi bf bh af lag h res topo
  up="${label^^}"
  va=$(rest A /info | jq -r '.appVersion // "null"'); vb=$(rest B /info | jq -r '.appVersion // "null"')
  echo "[$label] A (jvm) appVersion=$va jar=$(basename "${NODE_JAR[A]}")  B ($kind) appVersion=$vb bin=$(basename "${NODE_JAR[B]}") network=$(rest B /info | jq -r '.network // "?"')"
  echo "[$label] B /info at start: $(rest B /info | jq -c '{name, appVersion, network, fullHeight, headersHeight, peersCount}' 2>/dev/null)"
  end=$((SECONDS + 240))
  while [ $SECONDS -lt $end ]; do
    bi=$(rest B /info); bf=$(jq -r '.fullHeight // 0' <<< "$bi"); bh=$(jq -r '.headersHeight // 0' <<< "$bi"); af=$(full_height A)
    sc=$(same_chain A B); lag=$((af - bf)); [ $lag -gt $maxlag ] && maxlag=$lag
    echo "  A.full=$af  B.full=$bf B.hdr=$bh peers=$(jq -r '.peersCount // "?"' <<< "$bi")  same_chain=${sc:0:14}"
    case "$sc" in SAME@*) h=${sc#SAME@}; h=${h%%:*}; [ "${h:-0}" -ge 10 ] && followed=yes ;; DIFF@*) followed=DIFF ;; esac
    [ "${af:-0}" -ge 40 ] && [ $followed != no ] && break; sleep 5
  done
  echo "[$label] while A mined: B followed by header id: $followed (largest lag seen $maxlag blocks); stopping A's miner so B can settle"
  stop_mining A
  end=$((SECONDS + 150)); res=FAIL
  while [ $SECONDS -lt $end ]; do
    bi=$(rest B /info); bf=$(jq -r '.fullHeight // 0' <<< "$bi"); bh=$(jq -r '.headersHeight // 0' <<< "$bi"); st=$(same_state A B); sc=$(same_chain A B)
    echo "  settle: A.full=$(full_height A) B.full=$bf B.hdr=$bh same_chain=${sc:0:14} same_state=${st%%:*}"
    case "$st" in SAME@*) h=${st#SAME@}; h=${h%%:*}; [ "$bf" = "$bh" ] && [ "${h:-0}" -ge 30 ] && { res=PASS; break; } ;; DIFF@*) break ;; esac
    sleep 5
  done
  echo "[$label] B /blocks/at/1: $(rest B /blocks/at/1 | jq -c . 2>/dev/null)  A /blocks/at/1: $(rest A /blocks/at/1 | jq -c .)"
  echo "[$label] peers vs topology:"; check_topology && topo=ok || topo=mismatch
  echo "[$label] A sees: $(rest A /peers/connected | jq -c '[.[] | {name, address, connectionType}]')"
  echo "[$label] B sees: $(rest B /peers/connected | jq -c '[.[] | {name, address, connectionType}]')"
  [ "$topo" = ok ] || res=FAIL; [ $followed = yes ] || res=FAIL
  if [ "$va" = "$vb" ] || [ "$va" = null ] || [ "$vb" = null ]; then res=FAIL; echo "[$label] FAIL: appVersions are not two distinct versions (A=$va B=$vb)"; fi
  echo "[$label] === $up: $res (A=$va B=$vb followed=$followed maxlag=$maxlag ${sc%%:*} ${st%%:*} topology=$topo) ==="; rig_verdict=$res
  echo "$up-DONE"; }
