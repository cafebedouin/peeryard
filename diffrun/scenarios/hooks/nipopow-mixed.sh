# shellcheck shell=bash
# nipopow-mixed hook: A (this role's jar) mines and mints a prefix past a UTXO snapshot; B (this role's jar) follows,
# so A and B can serve a NiPoPoW proof. C (the other role's jar, ${PEERYARD_JAR_B}) is launched with
# nipopowBootstrap = true and asks A and B for a proof. The metric is whether C applies the served proof
# (proof_applied) or rejects it (rejected: "sent wrong nipopow") and stays at header height 0. Both arms are mixed,
# so base and candidate are the two directions of a proof-form change.
# RESULT_JSON carries a_served_proof, proof_applied, rejected, penalties, no_peers_logged, c_headers, and both
# appVersions. rig_verdict is PASS when the served proof is rejected (the reproduction), FAIL otherwise.
echo "[nipopow-mixed] waiting for A's first rewards to mature, then minting boxes"
wait_balance A 30000000000 300 >/dev/null || { echo "[nipopow-mixed] INCONCLUSIVE: A never had a spendable balance"; echo "RESULT_JSON $(jq -cn '{schema_version:1,scenario:"nipopow-mixed",inconclusive:"no A balance"}')"; rig_verdict=FAIL; return; }
h_mint0=$(full_height A); echo "[nipopow-mixed] minting from height $h_mint0: $(mint_boxes A 120 200)"
h_mint1=$(full_height A); snap=$(( (h_mint1 / 128 + 1) * 128 - 1 )); echo "[nipopow-mixed] minted by height $h_mint1; next snapshot at $snap"
end=$((SECONDS + 400)); while [ $SECONDS -lt $end ]; do h=$(full_height A); [ "${h:-0}" -ge $((snap + 8)) ] && break; sleep 3; done
echo "[nipopow-mixed] A at $(full_height A), B at $(full_height B)"
snap_a=no; grep -q 'dump utxo set snapshot' "$RIG_LOG_DIR/node_A.log" && snap_a=yes
start_mining A 3s >/dev/null
gen=$(genesis_id A) || { echo "[nipopow-mixed] INCONCLUSIVE: A gave no well-formed genesis id"; echo "RESULT_JSON $(jq -cn '{schema_version:1,scenario:"nipopow-mixed",inconclusive:"no genesis id"}')"; rig_verdict=FAIL; return; }
CONF_OVR[C]="ergo.chain.genesisId=\"$gen\""
# proofs built/served by A and B (the serving side has something to offer)
a_proofs=$(grep -c -i 'nipopow proof' "$RIG_LOG_DIR/node_A.log" 2>/dev/null || echo 0)
b_proofs=$(grep -c -i 'nipopow proof' "$RIG_LOG_DIR/node_B.log" 2>/dev/null || echo 0)
echo "[nipopow-mixed] genesis ${gen:0:16}; nipopow-proof log lines A/B: $a_proofs/$b_proofs"
launch C; wait_up C || { echo "[nipopow-mixed] INCONCLUSIVE: C never came up"; echo "RESULT_JSON $(jq -cn '{schema_version:1,scenario:"nipopow-mixed",inconclusive:"C did not come up"}')"; rig_verdict=FAIL; return; }
# C asks each reachable peer for a proof once; a cross-version proof is rejected within ~50 ms. Poll a few minutes
# to let the exchange happen and to confirm C does not recover by another path within the window.
t0=$SECONDS; end=$((SECONDS + 360))
while [ $SECONDS -lt $end ]; do
  ci=$(rest C /info); ch=$(jq -r '.headersHeight // 0' <<< "$ci"); cf=$(jq -r '.fullHeight // 0' <<< "$ci")
  rej=$(grep -c 'sent wrong nipopow' "$RIG_LOG_DIR/node_C.log" 2>/dev/null || echo 0)
  app=no; grep -q 'Nipopow proof applied' "$RIG_LOG_DIR/node_C.log" && app=yes
  echo "  t+$((SECONDS - t0))s A.full=$(full_height A) C.hdr=$ch C.full=$cf rejected=$rej applied=$app"
  { [ "$app" = yes ] || [ "${rej:-0}" -ge 2 ]; } && break
  sleep 10
done
proof_applied=no; grep -q 'Nipopow proof applied' "$RIG_LOG_DIR/node_C.log" && proof_applied=yes
rej=$(grep -c 'sent wrong nipopow' "$RIG_LOG_DIR/node_C.log" 2>/dev/null || echo 0)
# penalties: the node applies MisbehaviorPenalty on the rejected proof; count the misbehaviour/penalty lines, and
# fall back to the reject-line count (each reject penalises its peer) when the penalty is not logged at this level.
pen=$(grep -Eci 'misbehav|penal' "$RIG_LOG_DIR/node_C.log" 2>/dev/null || echo 0); [ "${pen:-0}" -lt "${rej:-0}" ] && pen=$rej
no_peers=no; grep -q 'No peers to ask NiPoPoWs from' "$RIG_LOG_DIR/node_C.log" && no_peers=yes
c_hdr=$(rest C /info | jq -r '.headersHeight // 0')
a_served=$([ "${a_proofs:-0}" -gt 0 ] || [ "${rej:-0}" -gt 0 ] && echo yes || echo no)
grep -Ei 'wrong nipopow|nipopow proof applied|No peers to ask NiPoPoWs' "$RIG_LOG_DIR/node_C.log" | tail -4 | cut -c1-170 | sed 's/^/    C: /'
va=$(rest A /info | jq -r '.appVersion // "null"'); vc=$(rest C /info | jq -r '.appVersion // "null"')
echo "[nipopow-mixed] A(serve)=$va C(join)=$vc; proof_applied=$proof_applied rejected=$rej penalties=$pen no_peers=$no_peers C-headers=$c_hdr; A snapshot logged=$snap_a"
echo "[nipopow-mixed] peers vs topology:"; check_topology || echo "  (mismatch reported)"
# PASS = the served cross-version proof was rejected and not applied (the mixed-version reproduction).
res=FAIL
if [ "${rej:-0}" -ge 1 ] && [ "$proof_applied" = no ]; then res=PASS; fi
echo "[nipopow-mixed] === NIPOPOW-MIXED: $res (serve=$va join=$vc rejected=$rej applied=$proof_applied C-headers=$c_hdr) ==="
echo "RESULT_JSON $(jq -cn \
  --arg A "$va" --arg C "$vc" \
  --argjson served "$([ "$a_served" = yes ] && echo true || echo false)" \
  --argjson applied "$([ "$proof_applied" = yes ] && echo true || echo false)" \
  --argjson rejected "$([ "${rej:-0}" -ge 1 ] && echo true || echo false)" \
  --argjson pen "${pen:-0}" \
  --argjson nopeers "$([ "$no_peers" = yes ] && echo true || echo false)" \
  --argjson chdr "${c_hdr:-0}" \
  --arg jv "$(${PEERYARD_JAVA:-java} -version 2>&1 | head -1)" \
  '{schema_version:1,scenario:"nipopow-mixed",runtime:{java:$jv},versions:{serve_A:$A,join_C:$C},metrics:{a_served_proof:$served,proof_applied:$applied,rejected:$rejected,penalties:$pen,no_peers_logged:$nopeers,c_headers:$chdr}}')"
rig_verdict=$res
