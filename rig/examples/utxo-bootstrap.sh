# utxo-bootstrap: a late node bootstraps from a UTXO-set snapshot instead of replaying every block. Two facts
# from the node decide the staging. (1) The snapshot period is a chain setting shared by all nodes
# (ergo.chain.makeSnapshotEvery, 52,224 on mainnet), set to 128 here, the devnet voting length: a node that
# stores snapshots (storingUtxoSnapshots > 0) takes one at h % 128 == 127 when its estimated network tip is within a
# period. The period must be a multiple of the voting length: a bootstrapping node rebuilds the state context as of
# an epoch end (ErgoStateReader.reconstructStateContextBeforeEpoch), so a snapshot at h % 128 == 63 (taken with a
# period of 64) is downloaded in full and never applied
# (UtxoSetSnapshotPersistence.saveSnapshotIfNeeded). (2) A snapshot is served as a manifest (the top of the
# AVL+ tree, depth 14: ManifestSerializer.MainnetManifestDepth) plus chunks (the subtrees below that depth).
# A fresh devnet's UTXO set has a few hundred boxes and no subtree at depth 14, so its manifest lists zero
# chunks, and a bootstrapping node, which applies the snapshot when the last chunk arrives, never applies it
# (witnessed in this example's first run: "Downloaded or waiting 0 chunks out of 0"). So A first mints about
# 24,000 boxes with mint_boxes (120 transactions of 200 outputs) and the run waits for the next snapshot
# boundary after that. Then C (deferred) is launched with utxoBootstrap = true and p2pUtxoSnapshots = 2 (the
# default quorum: two peers must serve the same snapshot at a height); it syncs headers, downloads the
# manifest and chunks, applies the snapshot and then only the full blocks after it.
#   PEERYARD_JAR=~/ergo-6.0.6.jar bash rig/rig.sh rig/examples/utxo-bootstrap.json rig/examples/utxo-bootstrap.sh
# PASS = C reaches the same state root as A at an equal height past the snapshot; C serves the header at height
# 5 but not that block's transactions (it bootstrapped, it did not replay); C's log records the snapshot
# download with chunks > 0.
# The prefix (matured rewards, minted boxes, a snapshot at `snap`) is long and the same every run: with
# PEERYARD_FIXTURES set it is built once, saved (fixture_save) and restored on later runs (rig.sh).
if fixture_restored; then
  echo "[utxo-bootstrap] prefix restored from a fixture: A and B at $(full_height A)/$(full_height B), snapshot at $snap (A logged it: $snap_a)"
else
  echo "[utxo-bootstrap] waiting for A's first rewards to mature, then minting boxes"
  wait_balance A 30000000000 300 >/dev/null || { echo "[utxo-bootstrap] FAIL: A never had a spendable balance"; rig_verdict=FAIL; return; }
  h_mint0=$(full_height A); echo "[utxo-bootstrap] minting from height $h_mint0: $(mint_boxes A 120 200)"
  h_mint1=$(full_height A); snap=$(( (h_mint1 / 128 + 1) * 128 - 1 )); echo "[utxo-bootstrap] minted by height $h_mint1; next snapshot at $snap; unspent boxes in A's wallet: $(wallet A /wallet/boxes/unspent | jq 'length' 2>/dev/null)"
  end=$((SECONDS + 400)); while [ $SECONDS -lt $end ]; do h=$(full_height A); [ "${h:-0}" -ge $((snap + 8)) ] && break; sleep 3; done
  echo "[utxo-bootstrap] A at $(full_height A), B at $(full_height B); snapshot lines in A's log: $(grep -c -i 'snapshot' "$RIG_LOG_DIR/node_A.log")"
  grep -i 'snapshot' "$RIG_LOG_DIR/node_A.log" | grep -v 'checking snapshot' | tail -3 | cut -c1-170 | sed 's/^/    A: /'
  snap_a=no; grep -q 'dump utxo set snapshot' "$RIG_LOG_DIR/node_A.log" && snap_a=yes
  fixture_save snap="$snap" snap_a="$snap_a"
fi
launch C; wait_up C || { echo "[utxo-bootstrap] FAIL: C never came up"; rig_verdict=FAIL; return; }
t0=$SECONDS; end=$((SECONDS + 480)); st=""; ok=no; paused=no
while [ $SECONDS -lt $end ]; do
  ci=$(rest C /info); cf=$(jq -r '.fullHeight // 0' <<< "$ci"); ch=$(jq -r '.headersHeight // 0' <<< "$ci")
  st=$(same_state A C)
  echo "  t+$((SECONDS - t0))s A.full=$(full_height A) C.hdr=$ch C.full=$cf same_state=${st%%:*} chunks(C)=$(grep -c 'chunks out of' "$RIG_LOG_DIR/node_C.log")"
  # once C is past the snapshot height, pause the miner so the two can be compared at an equal height
  if [ $paused = no ] && [ "${cf:-0}" -gt "$snap" ]; then stop_mining A >/dev/null; paused=yes; echo "  (C past the snapshot at $snap: miner paused for the comparison)"; fi
  case "$st" in SAME@*) h=${st#SAME@}; h=${h%%:*}; [ "${h:-0}" -ge "$snap" ] && { ok=yes; break; } ;; DIFF@*) break ;; esac
  sleep 10
done
hdr5=$(header_at C 5); txs5=$(block_txs C 5); txs5a=$(block_txs A 5)
grep -i 'snapshot' "$RIG_LOG_DIR/node_C.log" | grep -v 'checking snapshot' | tail -4 | cut -c1-170 | sed 's/^/    C: /'
snap_c=no; grep -E 'Downloaded or waiting [0-9]+ chunks out of [1-9]' "$RIG_LOG_DIR/node_C.log" >/dev/null && snap_c=yes
grep -E 'chunks out of' "$RIG_LOG_DIR/node_C.log" | tail -1 | cut -c1-170 | sed "s/^/    C: /"
echo "[utxo-bootstrap] C header@5=${hdr5:0:12} txs@5: C=$txs5 A=$txs5a; same_state=${st%%:*}; A snapshot logged=$snap_a; C snapshot logged=$snap_c"
echo "[utxo-bootstrap] peers vs topology:"; check_topology || echo "  (mismatch reported)"
res=FAIL
if [ $ok = yes ] && [ -n "$hdr5" ] && [ "${txs5:-0}" = 0 ] && [ "${txs5a:-0}" -ge 1 ] && [ $snap_c = yes ] && [ $snap_a = yes ]; then res=PASS; fi
echo "[utxo-bootstrap] === UTXO-BOOTSTRAP: $res (state=${st%%:*} hdr5=$([ -n "$hdr5" ] && echo yes || echo no) txs5=$txs5 A-snapshot=$snap_a C-snapshot=$snap_c) ==="; rig_verdict=$res
echo "UTXO-BOOTSTRAP-DONE"
