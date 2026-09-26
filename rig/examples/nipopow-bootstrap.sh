# nipopow-bootstrap: a late node bootstraps its header chain from a NiPoPoW proof served by honest peers and its
# state from a UTXO-set snapshot: the node's light bootstrap (nipopowBootstrap must be paired with utxoBootstrap or
# a pruned suffix, ErgoSettingsReader; a pruned digest variant is not shipped, so the UTXO
# snapshot pairing is used). Serving nodes take a proof 10 blocks before each snapshot height
# (HeadersProcessor: h % makeSnapshotEvery == makeSnapshotEvery - 1 - LastHeadersInContext) once their header
# chain is synced, and the snapshot at the height itself; the staging is utxo-bootstrap's (makeSnapshotEvery 128, the voting length,
# about 24,000 minted boxes so the snapshot has chunks). C (deferred) is launched with nipopowBootstrap = true,
# p2pNipopows = 1, utxoBootstrap = true, p2pUtxoSnapshots = 2 and the chain's genesis id (required with
# nipopowBootstrap; read from A's block at height 1).
#   PEERYARD_JAR=~/ergo-6.0.6.jar bash rig/rig.sh rig/examples/nipopow-bootstrap.json rig/examples/nipopow-bootstrap.sh
# PASS = C's log records the applied NiPoPoW proof and a chunked snapshot download; C reaches the same state root
# as A at an equal height past the snapshot; C does not hold block 5's transactions (whether it holds the header at
# height 5 is reported: a proof-bootstrapped node keeps a sparse prefix).
# The prefix (matured rewards, minted boxes, a snapshot at `snap`) is long and the same every run: with
# PEERYARD_FIXTURES set it is built once, saved (fixture_save) and restored on later runs (rig.sh).
if fixture_restored; then
  echo "[nipopow-bootstrap] prefix restored from a fixture: A and B at $(full_height A)/$(full_height B), snapshot at $snap (A logged it: $snap_a)"
else
  echo "[nipopow-bootstrap] waiting for A's first rewards to mature, then minting boxes"
  wait_balance A 30000000000 300 >/dev/null || { echo "[nipopow-bootstrap] FAIL: A never had a spendable balance"; rig_verdict=FAIL; return; }
  h_mint0=$(full_height A); echo "[nipopow-bootstrap] minting from height $h_mint0: $(mint_boxes A 120 200)"
  h_mint1=$(full_height A); snap=$(( (h_mint1 / 128 + 1) * 128 - 1 )); echo "[nipopow-bootstrap] minted by height $h_mint1; next snapshot at $snap; unspent boxes in A's wallet: $(wallet A /wallet/boxes/unspent | jq 'length' 2>/dev/null)"
  end=$((SECONDS + 400)); while [ $SECONDS -lt $end ]; do h=$(full_height A); [ "${h:-0}" -ge $((snap + 8)) ] && break; sleep 3; done
  echo "[nipopow-bootstrap] A at $(full_height A), B at $(full_height B); snapshot lines in A's log: $(grep -c -i 'snapshot' "$RIG_LOG_DIR/node_A.log")"
  grep -i 'snapshot' "$RIG_LOG_DIR/node_A.log" | grep -v 'checking snapshot' | tail -3 | cut -c1-170 | sed 's/^/    A: /'
  snap_a=no; grep -q 'dump utxo set snapshot' "$RIG_LOG_DIR/node_A.log" && snap_a=yes
  fixture_save snap="$snap" snap_a="$snap_a"
fi
# Slow A before C starts: with A on the prefix's 500 ms poll, C (which follows at about 0.35-0.5 blocks/s here) can
# fall behind for good, and pausing A later means restarting it while C catches up, which has stalled C before.
# Restarting A now, before C exists, is harmless (relaunch waits for A to reload its chain).
start_mining A 3s >/dev/null
# PEERYARD_NIPO_LEAD=<n> (optional): hold C back until A is n blocks past the snapshot, so that more headers arrive
# before C applies the snapshot than one post-snapshot download batch covers (a controlled condition for the
# near-tip scan floor; unset, C starts as soon as A is repaced)
if [ -n "${PEERYARD_NIPO_LEAD:-}" ]; then
  end=$((SECONDS + 400)); while [ $SECONDS -lt $end ]; do h=$(full_height A); [ "${h:-0}" -ge $((snap + PEERYARD_NIPO_LEAD)) ] && break; sleep 3; done
  echo "[nipopow-bootstrap] lead: A at $(full_height A) before C starts (snapshot $snap + ${PEERYARD_NIPO_LEAD})"
fi
gen=$(genesis_id A) || { echo "[nipopow-bootstrap] FAIL: A gave no well-formed genesis id"; rig_verdict=FAIL; return; }; CONF_OVR[C]="ergo.chain.genesisId=\"$gen\""; echo "[nipopow-bootstrap] genesis id ${gen:0:16}; proofs logged by A/B: $(grep -c -i 'nipopow proof' "$RIG_LOG_DIR/node_A.log")/$(grep -c -i 'nipopow proof' "$RIG_LOG_DIR/node_B.log")"
launch C; wait_up C || { echo "[nipopow-bootstrap] FAIL: C never came up"; rig_verdict=FAIL; return; }
t0=$SECONDS; end=$((SECONDS + 660)); st=""; ok=no; paused=no
while [ $SECONDS -lt $end ]; do
  ci=$(rest C /info); cf=$(jq -r '.fullHeight // 0' <<< "$ci"); ch=$(jq -r '.headersHeight // 0' <<< "$ci")
  st=$(same_state A C)
  echo "  t+$((SECONDS - t0))s A.full=$(full_height A) C.hdr=$ch C.full=$cf same_state=${st%%:*} chunks(C)=$(grep -c 'chunks out of' "$RIG_LOG_DIR/node_C.log")"
  # once C is past the snapshot height, pause the miner so the two can be compared at an equal height
  # pause the miner only once C has caught up to within a few blocks (a restart of A while C is still applying
  # the post-snapshot blocks was seen to leave C stalled), then compare at an equal height
  af=$(full_height A); if [ $paused = no ] && [ "${cf:-0}" -gt "$snap" ] && [ $((af - cf)) -le 3 ]; then stop_mining A >/dev/null; paused=yes; echo "  (C caught up past the snapshot at $snap: miner paused for the comparison)"; fi
  case "$st" in SAME@*) h=${st#SAME@}; h=${h%%:*}; [ "${h:-0}" -ge "$snap" ] && { ok=yes; break; } ;; DIFF@*) break ;; esac
  sleep 10
done
hdr5=$(header_at C 5); txs5=$(block_txs C 5); txs5a=$(block_txs A 5)
grep -i 'snapshot' "$RIG_LOG_DIR/node_C.log" | grep -v 'checking snapshot' | tail -4 | cut -c1-170 | sed 's/^/    C: /'
snap_c=no; grep -E 'Downloaded or waiting [0-9]+ chunks out of [1-9]' "$RIG_LOG_DIR/node_C.log" >/dev/null && snap_c=yes
proof=no; grep -q 'Nipopow proof applied' "$RIG_LOG_DIR/node_C.log" && proof=yes
grep 'Nipopow proof applied' "$RIG_LOG_DIR/node_C.log" | tail -1 | cut -c1-170 | sed "s/^/    C: /"
grep -E 'chunks out of' "$RIG_LOG_DIR/node_C.log" | tail -1 | cut -c1-170 | sed "s/^/    C: /"
echo "[nipopow-bootstrap] C header@5=${hdr5:0:12} txs@5: C=$txs5 A=$txs5a; same_state=${st%%:*}; A snapshot logged=$snap_a; C snapshot logged=$snap_c"
echo "[nipopow-bootstrap] peers vs topology:"; check_topology || echo "  (mismatch reported)"
res=FAIL
# a NiPoPoW-bootstrapped node holds a sparse prefix, so the header at height 5 is normally absent: reported, not judged
if [ $ok = yes ] && [ "${txs5:-0}" = 0 ] && [ "${txs5a:-0}" -ge 1 ] && [ $snap_c = yes ] && [ $proof = yes ]; then res=PASS; fi
echo "[nipopow-bootstrap] === NIPOPOW-BOOTSTRAP: $res (state=${st%%:*} proof=$proof hdr5=$([ -n "$hdr5" ] && echo yes || echo no) txs5=$txs5 C-snapshot=$snap_c C-headers=$(rest C /info | jq -r .headersHeight)) ==="; rig_verdict=$res
echo "NIPOPOW-BOOTSTRAP-DONE"
