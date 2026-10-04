# rig/lib/conf.sh: node configuration generators (gen_conf, gen_conf_arkadianet, gen_conf_ergo_node_rust).
# Sourced by rig.sh; scenario hooks may rely on hook_api.sh functions.
# TOML for an arkadianet node (docs/configuration.md of arkadianet/ergo; the values of its scripts/devnet-mixed/
# rust-node.toml with the rig's addresses). Mining stays off: the binary has no internal miner
# (use_external_miner must be true), so a mining arkadianet node needs a solver loop against /mining/*.
gen_conf_arkadianet(){ local n="$1"; local f="$SCRATCH/conf_$n.toml" dir="$SCRATCH/data_$n" kp extra mining
  mkdir -p "$dir"
  mining="${MINING_OVR[$n]:-$(jq -r --arg n "$n" 'first(.nodes[]|select(.name==$n).mining) // false' "$CFG")}"
  kp="$(known_peer_addrs "$n" | sed 's/.*/"&"/' | paste -sd, -)"
  extra="$(jq -r --arg n "$n" '.nodes[]|select(.name==$n).conf // {} | to_entries[]? | "\(.key) = \(.value)"' "$CFG")"
  {
    echo 'network = "devnet"'
    echo "data_dir = \"$dir\""
    [[ $RUST_MAGIC_OVERRIDE == 1 ]] && { echo '[chain]'; echo "devnet_magic = $MAGIC"; }
    echo '[node]'; echo "node_name = \"$n\""; echo 'agent_name = "ergo-rust"'
    echo '[peers]'; echo "known = [$kp]"; echo "bind_addr = \"0.0.0.0:${P2P[$n]}\""; echo "declared_addr = \"${IP[$n]}:${P2P[$n]}\""
    echo 'allow_local = true'
    echo '[sync]'; echo 'sync_interval_secs = 1'; echo 'sync_interval_stable_secs = 1'
    echo '[api]'; echo "bind = \"127.0.0.1:${REST[$n]}\""
    echo '[api.security]'; echo "api_key_hash = \"$API_KEY_HASH\""
    # "mining": true serves candidates on /mining/* for an external solver (solve_start); rewards go to the
    # public test key below (secret scalar 1, the key the node's own mixed-devnet recipe uses)
    if [[ "$mining" == "true" ]]; then
      echo '[mining]'; echo 'enabled = true'; echo 'use_external_miner = true'; echo "miner_public_key_hex = \"$SOLVER_PK\""
    fi
    while IFS= read -r line; do [[ -n "$line" ]] && echo "$line"; done <<< "$extra"
    [[ -n "${CONF_OVR[$n]:-}" ]] && printf '%s\n' "${CONF_OVR[$n]}"
  } > "$f"; echo "$f"; }
# TOML for an ergo-node-rust node (its ergo.toml.example): [proxy] network selects the chain; the node binary
# takes the config path as its argument.
gen_conf_ergo_node_rust(){ local n="$1"; local f="$SCRATCH/conf_$n.toml" dir="$SCRATCH/data_$n" kp extra
  mkdir -p "$dir"
  kp="$(known_peer_addrs "$n" | sed 's/.*/"&"/' | paste -sd, -)"
  extra="$(jq -r --arg n "$n" '.nodes[]|select(.name==$n).conf // {} | to_entries[]? | "\(.key) = \(.value)"' "$CFG")"
  {
    echo '[proxy]'; echo 'network = "devnet"'
    [[ $RUST_MAGIC_OVERRIDE == 1 ]] && echo "magic = $MAGIC"
    echo '[listen.ipv4]'; echo "address = \"0.0.0.0:${P2P[$n]}\""; echo 'mode = "full"'; echo 'max_inbound = 20'
    echo '[outbound]'; echo 'min_peers = 1'; echo 'max_peers = 10'; echo "seed_peers = [$kp]"
    echo '[identity]'; echo 'agent_name = "ergo-node-rust"'; echo "peer_name = \"$n\""; echo 'protocol_version = "6.0.3"'
    echo '[node]'; echo "data_dir = \"$dir\""; echo 'state_type = "utxo"'; echo 'blocks_to_keep = -1'
    echo "api_address = \"127.0.0.1:${REST[$n]}\""
    while IFS= read -r line; do [[ -n "$line" ]] && echo "$line"; done <<< "$extra"
    [[ -n "${CONF_OVR[$n]:-}" ]] && printf '%s\n' "${CONF_OVR[$n]}"
  } > "$f"; echo "$f"; }
gen_conf() {  # $1 = node name -> prints the conf path (SCRATCH_DATA_OVERRIDE: a throwaway data dir for the digest probe)
  local n="$1"; local f="$SCRATCH/conf_$n.conf" dir="${SCRATCH_DATA_OVERRIDE:-$SCRATCH/data_$n}"
  case "${KIND[$n]:-jvm}" in arkadianet) gen_conf_arkadianet "$n"; return ;; ergo-node-rust) gen_conf_ergo_node_rust "$n"; return ;; esac
  [[ -n "${SCRATCH_DATA_OVERRIDE:-}" ]] && f="$SCRATCH_DATA_OVERRIDE/conf_$n.conf"
  mkdir -p "$dir"
  local mining kp extra poll
  mining="${MINING_OVR[$n]:-$(jq -r --arg n "$n" 'first(.nodes[]|select(.name==$n).mining) // false' "$CFG")}"
  # mining rate: runtime override > per-node "mine_poll" > 500ms. A large mine_poll (e.g. "45s") leaves the
  # miner idle between rare blocks, without a restart.
  poll="${POLL_OVR[$n]:-$(jq -r --arg n "$n" --arg d "$DEFAULT_POLL" 'first(.nodes[]|select(.name==$n).mine_poll) // $d' "$CFG")}"
  # knownPeers names -> "ip:p2p", dialing each peer at its identity address
  kp="$(jq -r --arg n "$n" '.nodes[]|select(.name==$n).knownPeers[]?' "$CFG" | while read -r pn; do
        [[ -z "$pn" ]] && continue
        printf '"%s:%s",' "${IP[$pn]}" "${P2P[$pn]}"; done)"
  kp="[${kp%,}]"
  # extra HOCON lines, given per node as {"dotted.key": "value"}
  extra="$(jq -r --arg n "$n" '.nodes[]|select(.name==$n).conf // {} | to_entries[]? | "\(.key)=\(.value)"' "$CFG")"
  {
    echo "ergo.directory=\"$dir\""
    echo "ergo.node.mining=$mining"
    echo "ergo.node.offlineGeneration=$mining"
    # PEERYARD_EXTMINE_POLL: no internal CPU miner; rig/lib/extminer.py mines through /mining/* (rig.sh extmine_start)
    if [[ "$mining" == "true" && -n "${EXTMINE_POLL:-}" ]]; then echo "ergo.node.useExternalMiner=true"
    else echo "ergo.node.useExternalMiner=false"; [[ "$mining" == "true" ]] && echo "ergo.node.internalMinerPollingInterval=$poll"; fi
    echo "ergo.wallet.testMnemonic=\"$MNEMONIC\""
    echo "ergo.wallet.testKeysQty=5"
    echo "scorex.network.bindAddress=\"0.0.0.0:${P2P[$n]}\""
    echo "scorex.network.declaredAddress=\"${IP[$n]}:${P2P[$n]}\""
    echo "scorex.network.knownPeers=$kp"
    echo "scorex.network.allowLocal=true"
    echo "scorex.network.localOnly=true"   # the same switch under its older name (releases before v6.0.3 read only this; later ones ignore it)
    echo "scorex.network.nodeName=\"$n\""
    echo "scorex.restApi.bindAddress=\"127.0.0.1:${REST[$n]}\""
    echo "scorex.restApi.apiKeyHash=\"$API_KEY_HASH\""
    echo "scorex.network.magicBytes=$MAGIC"
    # Devnet settings matched to the node's own integration-test template (src/it/resources/devnetTemplate.conf),
    # so that a sole-peer follower fully syncs and a restarted node keeps its chain (rig/examples/floor.*).
    echo "ergo.node.stateType=utxo"
    echo "ergo.node.verifyTransactions=true"
    echo "ergo.node.blocksToKeep=-1"
    echo "ergo.node.mempoolCapacity=10000"
    echo "ergo.chain.powScheme.powType=autolykos"
    echo "ergo.chain.powScheme.k=32"
    echo "ergo.chain.powScheme.n=26"
    [[ $RUST_DEVNET == 1 ]] && jvm_rust_devnet_conf
    [[ -n "$BLOCK_INTERVAL" ]] && echo "ergo.chain.blockInterval=$BLOCK_INTERVAL"
    [[ -n "$REWARD_DELAY" ]] && echo "ergo.chain.monetary.minerRewardDelay=$REWARD_DELAY"
    [[ -n "$GENESIS_DIGEST" ]] && echo "ergo.chain.genesisStateDigestHex=\"$GENESIS_DIGEST\""
    [[ "$V4" == true ]] && printf '%s\n' "ergo.chain.voting.votingLength=4" "ergo.chain.voting.softForkEpochs=1" "ergo.chain.voting.activationEpochs=1"
    while IFS= read -r line; do [[ -n "$line" ]] && echo "$line"; done <<< "$extra"
    # runtime HOCON lines set by the hook before a deferred launch, e.g. a genesisId pin
    [[ -n "${CONF_OVR[$n]:-}" ]] && printf '%s\n' "${CONF_OVR[$n]}"
  } > "$f"
  echo "$f"
}
