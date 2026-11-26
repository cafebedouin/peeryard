# shellcheck shell=bash
# nipopow-cutover hook. A and B start on the base jar (${DIFFRUN_BASE_JAR}); A mines and mints a prefix past a UTXO
# snapshot, so both hold a NiPoPoW proof stored by the base. Then every node named in UPGRADE ("A B", "B" or "none")
# is restarted in place, on its own database, on this role's jar: in the base role that is the base jar again (the
# control: same restarts, no change); in the candidate role it is the candidate jar, announcing NEWVER in the
# handshake (scorex.network.appVersion), the stand-in for the release that ships the change. With AGE=1 the servers
# are then taken past their next proof height before the joiner starts, so the proof stored by the base is one
# period old. The joiner C is launched with nipopowBootstrap = true and p2pNipopows = QUORUM: in the base role on the
# base jar; in the candidate role on the candidate jar announcing NEWVER (JOINER=new) or on the base jar (JOINER=old).
# RESULT_JSON `versions` lists the nodes on this role's jar only (the runner checks them against that jar's
# appVersion; /info reports the build's version, not the announced one); every node's version is printed in the
# summary line. rig_verdict is PASS when C applied a proof and rejected none.
# The servers keep one UTXO snapshot (storingUtxoSnapshots = 1 in the topology). With two, a joiner that hears the
# snapshot list before it has synced the headers up to the newer snapshot can settle on the older one, below its
# proof's suffix, and stay there (seen on the base jar too); that is another question than this scenario's.
nc_die(){ echo "[nipopow-cutover] INCONCLUSIVE: $1"; echo "RESULT_JSON $(jq -cn --arg r "$1" '{schema_version:1,scenario:"nipopow-cutover",inconclusive:$r}')"; rig_verdict=FAIL; }
role="${DIFFRUN_ROLE:-candidate}"; base_jar="$(readlink -f "${DIFFRUN_BASE_JAR:?}")"; role_jar="$(readlink -f "${PEERYARD_JAR:?}")"
upgrade="${UPGRADE:-A B}"; [ "$upgrade" = none ] && upgrade=""
newver=""; [ "$role" = candidate ] && newver="${NEWVER:-6.0.12}"
set_jar(){ # $1=node $2=jar: the node's next launch runs this jar, with the jar's own configuration files
  NODE_JAR[$1]="$2"; mkdir -p "${RT_CWD[$1]}/src/main/resources"
  unzip -o -q "$2" application.conf devnet.conf mainnet.conf testnet.conf -d "${RT_CWD[$1]}/src/main/resources"; }
is_upgraded(){ case " $upgrade " in *" $1 "*) return 0 ;; esac; return 1; }
since_upgrade(){ tail -n +"$(( ${UP_LINE[$1]:-0} + 1 ))" "$RIG_LOG_DIR/node_$1.log"; }
declare -A UP_LINE

echo "[nipopow-cutover] role=$role upgrade='${upgrade:-none}' joiner=${JOINER:-new} quorum=${QUORUM:-1} age=${AGE:-0} newver=${newver:-unchanged}"
echo "[nipopow-cutover] waiting for A's first rewards to mature, then minting boxes"
wait_balance A 30000000000 300 >/dev/null || { nc_die "no A balance"; return; }
h_mint0=$(full_height A); echo "[nipopow-cutover] minting from height $h_mint0: $(mint_boxes A 120 200)"
h_mint1=$(full_height A); snap=$(( (h_mint1 / 128 + 1) * 128 - 1 )); echo "[nipopow-cutover] minted by height $h_mint1; next snapshot at $snap"
end=$((SECONDS + 400)); while [ $SECONDS -lt $end ]; do h=$(full_height A); [ "${h:-0}" -ge $((snap + 8)) ] && break; sleep 3; done
echo "[nipopow-cutover] A at $(full_height A), B at $(full_height B); proofs stored on the base jar: A=$(grep -c 'Dumping nipopow proof' "$RIG_LOG_DIR/node_A.log") B=$(grep -c 'Dumping nipopow proof' "$RIG_LOG_DIR/node_B.log")"
grep -q 'Dumping nipopow proof' "$RIG_LOG_DIR/node_B.log" || { nc_die "B stored no proof on the base jar"; return; }

# the in-place upgrade (the control restarts the same nodes on the base jar)
for n in $upgrade; do
  UP_LINE[$n]=$(wc -l < "$RIG_LOG_DIR/node_$n.log")
  set_jar "$n" "$role_jar"; [ -n "$newver" ] && CONF_OVR["$n"]="scorex.network.appVersion = $newver"
  echo "[nipopow-cutover] restarting $n in place on $(basename "$role_jar") (announces ${newver:-the jar default}) at height $(full_height "$n")"
  relaunch "$n"
done
next_proof=$((snap + 128 - 10))
if [ "${AGE:-0}" = 1 ]; then
  echo "[nipopow-cutover] ageing: taking A past the next snapshot at $((snap + 128))"
  end=$((SECONDS + 400)); while [ $SECONDS -lt $end ]; do h=$(full_height A); [ "${h:-0}" -ge $((snap + 128 + 8)) ] && break; sleep 3; done
  next_proof=$((next_proof + 128))
fi
start_mining A 3s >/dev/null
# a few new headers for the restarted nodes (A mines at 3 s) before C starts
h0=$(full_height A); end=$((SECONDS + 90)); while [ $SECONDS -lt $end ]; do h=$(full_height A); [ "${h:-0}" -ge $((h0 + 5)) ] && break; sleep 2; done
echo "[nipopow-cutover] A at $(full_height A) before C starts; the servers' next proof height is $next_proof"

gen=$(genesis_id A) || { nc_die "no genesis id"; return; }
c_jar="$base_jar"; c_ver=""
if [ "$role" = candidate ] && [ "${JOINER:-new}" = new ]; then c_jar="$role_jar"; c_ver="$newver"; fi
set_jar C "$c_jar"
CONF_OVR[C]="ergo.chain.genesisId=\"$gen\"
ergo.node.nipopow.p2pNipopows = ${QUORUM:-1}"
[ -n "$c_ver" ] && CONF_OVR[C]+="
scorex.network.appVersion = $c_ver"
launch C; wait_up C || { nc_die "C did not come up"; return; }
t0=$SECONDS; end=$((SECONDS + 480)); st=""; synced=no; paused=no
while [ $SECONDS -lt $end ]; do
  ci=$(rest C /info); cf=$(jq -r '.fullHeight // 0' <<< "$ci"); ch=$(jq -r '.headersHeight // 0' <<< "$ci")
  st=$(same_state A C)
  echo "  t+$((SECONDS - t0))s A.full=$(full_height A) C.hdr=$ch C.full=$cf same_state=${st%%:*} applied=$(grep -c 'Nipopow proof applied' "$RIG_LOG_DIR/node_C.log")"
  af=$(full_height A); if [ $paused = no ] && [ "${cf:-0}" -gt "$snap" ] && [ $((af - cf)) -le 3 ]; then stop_mining A >/dev/null; paused=yes; fi
  case "$st" in SAME@*) h=${st#SAME@}; h=${h%%:*}; [ "${h:-0}" -ge "$snap" ] && { synced=yes; break; } ;; DIFF@*) break ;; esac
  sleep 10
done

C_LOG="$RIG_LOG_DIR/node_C.log"
applied=no; grep -q 'Nipopow proof applied' "$C_LOG" && applied=yes
wrong=$(grep -c 'sent wrong nipopow' "$C_LOG"); misb=$(grep -c 'MisbehaviorPenalty' "$C_LOG"); nopeers=$(grep -c 'No peers to ask NiPoPoWs from' "$C_LOG")
bytes=$(grep -m1 -o 'Got valid nipopow proof, size: [0-9]*' "$C_LOG" | grep -o '[0-9]*$'); bytes=${bytes:-0}
t_proof=$(grep -m1 'Got valid nipopow proof' "$C_LOG" | cut -c1-12)
asked_up=0; asked_not=0; rebuilt=0; nocached=0; t_dump=""
for n in A B; do
  asked=$(grep -c "GetNipopowProof) to ConnectionId(remote=/$(node_ip "$n"):" "$C_LOG")
  if is_upgraded "$n"; then
    asked_up=$((asked_up + asked))
    rebuilt=$((rebuilt + $(since_upgrade "$n" | grep -c 'Rebuilt stored nipopow proof')))
    nocached=$((nocached + $(since_upgrade "$n" | grep -c -E 'No cached Nipopow proof|No Nipopow Proof available')))
    d=$(since_upgrade "$n" | grep -m1 'Dumping nipopow proof' | cut -c1-12)
    [ -n "$d" ] && { [ -z "$t_dump" ] || [[ "$d" < "$t_dump" ]]; } && t_dump="$d"
    since_upgrade "$n" | grep -E 'Rebuilt stored nipopow proof|Dumping nipopow proof' | head -3 | cut -c1-150 | sed "s/^/    $n: /"
    since_upgrade "$n" | grep -m1 -E 'No cached Nipopow proof|No Nipopow Proof available' | cut -c1-150 | sed "s/^/    $n: /"
  else
    asked_not=$((asked_not + asked))
  fi
done
# C's first valid proof came before any upgraded server passed its next proof height (false when C got no proof)
before=no; if [ -n "$t_proof" ] && { [ -z "$t_dump" ] || [[ "$t_proof" < "$t_dump" ]]; }; then before=yes; fi
c_hdr=$(rest C /info | jq -r '.headersHeight // 0')
grep -E 'Got valid nipopow proof|sent wrong nipopow|Nipopow proof applied' "$C_LOG" | head -3 | cut -c1-150 | sed 's/^/    C: /'
grep -m1 'MisbehaviorPenalty' "$C_LOG" | cut -c1-150 | sed 's/^/    C: /'
grep -m1 'failed validation' -A1 "$C_LOG" | tail -1 | cut -c1-170 | sed 's/^/    C: /'
va=$(rest A /info | jq -r '.appVersion // "null"'); vb=$(rest B /info | jq -r '.appVersion // "null"'); vc=$(rest C /info | jq -r '.appVersion // "null"')
versions=$(for n in A B C; do [ "${NODE_JAR[$n]}" = "$role_jar" ] && printf '%s\t%s\n' "$n" "$(rest "$n" /info | jq -r '.appVersion // "null"')"; done | jq -Rn '[inputs | split("\t") | {(.[0]): .[1]}] | add // {}')
echo "[nipopow-cutover] versions A=$va B=$vb C=$vc; first valid proof at ${t_proof:-never}, first proof stored by an upgraded server after its restart at ${t_dump:-never}"
echo "[nipopow-cutover] peers vs topology:"; check_topology || echo "  (mismatch reported)"
res=FAIL; [ "$applied" = yes ] && [ "${wrong:-0}" = 0 ] && res=PASS
echo "[nipopow-cutover] === NIPOPOW-CUTOVER: $res (role=$role applied=$applied synced=$synced wrong=$wrong misbehavior=$misb no_peers=$nopeers asked_upgraded=$asked_up asked_not_upgraded=$asked_not rebuilt=$rebuilt no_cached=$nocached proof_before_next_dump=$before bytes=$bytes C-headers=$c_hdr) ==="
b(){ [ "$1" = yes ] && echo true || echo false; }
echo "RESULT_JSON $(jq -cn --argjson versions "$versions" --arg jv "$(${PEERYARD_JAVA:-java} -version 2>&1 | head -1)" \
  --argjson applied "$(b $applied)" --argjson synced "$(b $synced)" --argjson before "$(b $before)" \
  --argjson wrong "${wrong:-0}" --argjson misb "${misb:-0}" --argjson nopeers "${nopeers:-0}" \
  --argjson asked_up "$asked_up" --argjson asked_not "$asked_not" --argjson rebuilt "$rebuilt" --argjson nocached "$nocached" \
  --argjson bytes "$bytes" --argjson chdr "${c_hdr:-0}" --argjson pass "$([ "$res" = PASS ] && echo true || echo false)" \
  '{schema_version:1,scenario:"nipopow-cutover",runtime:{java:$jv},versions:$versions,metrics:{pass:$pass,proof_applied:$applied,synced:$synced,wrong_proof:$wrong,misbehavior:$misb,no_peers:$nopeers,asked_upgraded:$asked_up,asked_not_upgraded:$asked_not,rebuilt:$rebuilt,no_cached:$nocached,proof_before_next_dump:$before,proof_bytes:$bytes,c_headers:$chdr}}')"
rig_verdict=$res
