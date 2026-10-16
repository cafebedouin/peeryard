# lithos-block: the Lithos proof of concept end to end on a fresh devnet. One indexed mining node A at block version 4,
# 20 s blocks, zero mempool fee floor, candidate regenerated on every mempool change, mining to the client's own key:
# the node's wallet and the client's keystore are the same key set, as a Lithos miner's are. The hook runs the client's
# deployer (tools.DeployProtocol) against A through the appkit proxy, which mints the protocol tokens and creates the
# emission, config, FP-control and dictionary boxes from the key's matured rewards; funds a due-job box (the client's
# reference contract, DueJob.ergo); writes a client config that reads the deployment descriptor and joins the collateral
# queue by itself; starts the client; then waits for a Lithos block: one whose first transaction spends a box holding
# the deployment's collateral token, and which also carries the heartbeat successor. PASS = that block exists.
#
# Node A: external-miner mode, mining key = the client's key, mined by rig/lib/devnet-miner.sh (needs javac at 17).
# Needs: LITHOS_STAGE (the staged client distribution), LITHOS_KEYSTORE and LITHOS_PASS (the client's wallet keystore
# JSON and its password), LITHOS_MNEMONIC (the same wallet's mnemonic, restored into node A's wallet so A mines to it),
# LITHOS_PUBKEY (that wallet's EIP-3 index 0 raw public key), JAVA_HOME at 17. Secrets stay in the environment.
: "${LITHOS_STAGE:?the staged client distribution directory}"; : "${LITHOS_KEYSTORE:?the client keystore json}"; : "${LITHOS_PASS:?the keystore password}"; : "${LITHOS_MNEMONIC:?the client wallet mnemonic}"
JAVA_HOME="${JAVA_HOME:-/usr/lib/jvm/java-17-openjdk-amd64}"; HERE_LIB="$(cd "$(dirname "$RIG_HOOK")/../lib" && pwd)"
PROXY_PORT=${PROXY_PORT:-9153}; WD="$SCRATCH/lithos"; mkdir -p "$WD"; CHECKS="$WD/checks.jsonl"; : > "$CHECKS"
DESC="$WD/deployment.json"; CONF="$WD/client.conf"
TREE=1b8f01040400040005000400d804d601e4c6a70504d602e4c6a70605d603b2a5730000d604c1a7d1edededededededededed9172017301927202730293c5b2a4730300c5a7927ea3059a7ee4c6a70404057e72010593c27203c2a793db63087203db6308a793e4c672030404a3938cc7720301a393e4c672030504720193e4c672030605720292c17203997204a172027204
ADDR=BLeBj4M5DTjaKjyEUwPF8JE7b6E4haYuHXwms5Rhf7mCThPdAnTdwPBHVTugWGXSgRzyt156JiWMSp31zuw3J3Vagvw1XGHQf1K7AUULYm64u8yWm6qVNpBQ3vBUWZS3tBkAExSYVFWz54M38YaZbVPLnPUx9HMNpnPiqzTz6Si1AQCPKUXUJS14aCTFc4TfF6RiqeEn2jUfHp
sint(){ python3 -c '
import sys; n=int(sys.argv[1]); z=((n<<1)^(n>>31))&0xffffffff; out=[]
while True:
  b=z&0x7f; z>>=7
  if z: out.append(b|0x80)
  else: out.append(b); break
print("04"+"".join("%02x"%b for b in out))' "$1"; }
in_a(){ ip netns exec "${NS[A]}" "$@"; }
rest_post(){ in_a curl -s --max-time 20 -X POST -H 'Content-Type: application/json' "http://127.0.0.1:${REST[A]}$1" --data "$2"; }
boxes_at_tree(){ rest_post /blockchain/box/unspent/byErgoTree "\"$TREE\""; }
block_txs(){ local hid; hid=$(header_at A "$1"); [[ -n "$hid" ]] && rest A "/blocks/$hid/transactions" | jq -c '.transactions'; }
fail(){ echo "[lb] FAIL: $*"; rig_verdict=FAIL; }
rig_verdict=FAIL
# 0. node A's wallet is the client's keystore key set, restored over the API from the mnemonic (a wallet from a test
# mnemonic would use the root key and its children, not the EIP-3 path a keystore derives). A mines internally first:
# the first blocks are Autolykos v1 work (no height in the work message), which only the node's own miner can solve.
: "${LITHOS_PUBKEY:?the raw hex public key of the keystore EIP-3 index 0 address}"
launch A; wait_up A || { fail "A did not come up"; return 0 2>/dev/null || exit 0; }
r=$(wallet A /wallet/restore "{\"pass\":\"$LITHOS_PASS\",\"mnemonic\":\"$LITHOS_MNEMONIC\",\"usePre1627KeyDerivation\":false}")
wallet A /wallet/unlock "{\"pass\":\"$LITHOS_PASS\"}" >/dev/null
echo "[lb] A's wallet restored ($r); wallet $(address A)"
# 1. block version 4 and a matured wallet on A
end=$((SECONDS + 600)); bv=""
while [[ $SECONDS -lt $end ]]; do bv=$(rest A /info | jq -r '.parameters.blockVersion // empty'); [[ "$bv" == 4 ]] && break; sleep 10; done
[[ "$bv" == 4 ]] || { fail "block version 4 did not activate"; return 0 2>/dev/null || exit 0; }
wait_balance A 400000000000 600 >/dev/null || { fail "A's wallet never reached 400 ERG"; return 0 2>/dev/null || exit 0; }
# 1b. from here A mines with the client's key, externally: the internal miner takes the wallet's first secret and
# ignores miningPubKeyHex, and the node serves a cached candidate only to a requester with the same key as the
# candidate names, which for the client's packages is its collateral lender. The rig's CPU miner solves A's candidates.
CONF_OVR[A]=$'ergo.node.useExternalMiner=true\nergo.node.miningPubKeyHex="'"$LITHOS_PUBKEY"'"'
relaunch A || { fail "A did not come back in external-miner mode"; return 0 2>/dev/null || exit 0; }
wallet A /wallet/unlock "{\"pass\":\"$LITHOS_PASS\"}" >/dev/null
echo "[lb] A relaunched; miner key $(wallet A /mining/rewardPublicKey | jq -r .rewardPubkey)"
companion_start miner --in A -- "$HERE_LIB/devnet-miner.sh" "${NODE_JAR[A]}" --node "http://127.0.0.1:${REST[A]}" --api-key hello
# 2. the proxy
companion_start proxy --in A -- python3 "$HERE_LIB/appkit-proxy.py" --listen "127.0.0.1:$PROXY_PORT" \
  --upstream "http://127.0.0.1:${REST[A]}" --record-checks "$CHECKS"; sleep 2
# 2b. a plain box for the key: mining rewards sit under the reward script with this chain's delay, which the client's
# wallet code reads with the mainnet delay, so neither the deployer nor the client can spend them directly
pay=$(wallet A /wallet/payment/send "[{\"address\":\"$(address A)\",\"value\":150000000000}]" | jq -r 'if type=="string" then . else (.detail // tojson) end')
echo "[lb] 150 ERG paid to a plain box of the key: $pay"
end=$((SECONDS + 300)); have=0
while [[ $SECONDS -lt $end ]]; do have=$(rest_post /blockchain/box/unspent/byAddress "\"$(address A)\"" | jq -r '[.[]?.value] | add // 0'); [[ "$have" -ge 150000000000 ]] && break; sleep 10; done
[[ "$have" -ge 150000000000 ]] || { fail "the plain box never confirmed ($have)"; return 0 2>/dev/null || exit 0; }
# 3. the deployment: tokens, protocol boxes, descriptor; the LIT not placed in the emission box stays with this key
# the stage's launcher jar carries the classpath in its manifest, so `-main` cannot see the app; run the class directly
( cd "$WD" && in_a env JAVA_HOME="$JAVA_HOME" PATH="$JAVA_HOME/bin:$PATH" java -cp "$LITHOS_STAGE/lib/*" tools.DeployProtocol \
    --node "http://127.0.0.1:$PROXY_PORT" --api-key hello --keystore "$LITHOS_KEYSTORE" --pass "$LITHOS_PASS" --network TESTNET \
    --out "$DESC" --timeout-seconds 1500 ) > "$WD/deploy.log" 2>&1
rc=$?; tail -5 "$WD/deploy.log" | cut -c1-200
[[ $rc == 0 && -s "$DESC" ]] || { fail "the deployer exited $rc (see $WD/deploy.log)"; return 0 2>/dev/null || exit 0; }
COLLAT=$(jq -r .collatToken "$DESC"); LIT=$(jq -r .litId "$DESC"); echo "[lb] deployed: collateral token $COLLAT, LIT $LIT, at height $(jq -r .height "$DESC")"
# 4. a due-job box, due at once
H=$(full_height A); R4=$(sint $((H - 10)))
tx=$(wallet A /wallet/transaction/send "{\"requests\":[{\"address\":\"$ADDR\",\"value\":1000000000,\"registers\":{\"R4\":\"$R4\",\"R5\":\"040a\",\"R6\":\"0580dac409\"}}],\"fee\":1000000}" | jq -r 'if type=="string" then . else (.detail // tojson) end')
echo "[lb] due-job box funded at height $H: tx $tx"
# 5. the client: reads the deployment, joins the queue by itself, carries upkeep in candidate mode
cat > "$CONF" <<EOC
include "application"
node { url = "http://127.0.0.1:$PROXY_PORT", key = "hello", storagePath = "$LITHOS_KEYSTORE", pass = "$LITHOS_PASS", networkType = "TESTNET", numAddresses = 1
       deployment { file = "$DESC" } }
sync.startHeight = 2
stats.enabled = false
batching.ergodex.enabled = false
batching.lithosdex.enabled = false
stratum.candidate.sources.rent.enabled = false
stratum.candidate.sources.ergodex.enabled = false
stratum.candidate.sources.lithosdex.enabled = false
emission { maxLenderKeys = 1, autoCollateralize = true, collateralizeInterval = 30000, queueInterval = 30000 }
stratum.candidate.sources.upkeep { enabled = true, mode = "candidate", verifyWithNode = true, scanIntervalMs = 10000, jobs.heartbeat { enabled = true } }
EOC
# by classpath from this run's directory, not the stage launcher: the launcher pins user.dir to the stage, so every
# client run would share one .lithos store there (the NISP and dictionary stores are hard-coded under .lithos)
cd "$WD"; companion_start client --in A -- env JAVA_HOME="$JAVA_HOME" PATH="$JAVA_HOME/bin:$PATH" \
  java -cp "$LITHOS_STAGE/lib/*" -Dconfig.file="$CONF" -Dhttp.port=9100 -Dpidfile.path=/dev/null play.core.server.ProdServerStart; cd - >/dev/null
CLIENT_LOG="$(companion_log client)"
# 6. a Lithos block carrying the beat: first transaction spends a box holding the collateral token; the beat is in it
start=$(full_height A); end=$((SECONDS + 1800)); found=""
while [[ -z "$found" && $SECONDS -lt $end ]]; do sleep 15; h=$(full_height A)
  for ((k = start; k <= h; k++)); do txs=$(block_txs "$k") || continue; [[ -n "$txs" ]] || continue
    # the first non-coinbase transaction (the coinbase is the emission spend; the genesis follows it)
    genesis=$(jq -c '[.[] | select(.inputs | length > 0)] | .[1] // empty' <<<"$txs")
    [[ -n "$genesis" ]] || continue
    gin=$(jq -r '.inputs[0].boxId' <<<"$genesis")
    holds=$(rest A "/blockchain/box/byId/$gin" | jq -r --arg t "$COLLAT" '[.assets[]? | select(.tokenId==$t)] | length')
    [[ "$holds" -ge 1 ]] || continue
    beat=$(jq -r --arg tree "$TREE" '[.[] | select(.outputs[]? | .ergoTree == $tree)] | length' <<<"$txs")
    echo "[lb] Lithos block at $k: genesis $(jq -r .id <<<"$genesis" | cut -c1-8) spends collateral box $gin; beats in block: $beat"
    [[ "$beat" -ge 1 ]] && { found=$k; break; }
  done
  start=$((h + 1))
done
grep -E "Upkeep|genesis|Join|Activate|collateral" "$CLIENT_LOG" | grep -v "^\s*at " | tail -12 | cut -c1-200
if [[ -n "$found" ]]; then echo "[lb] PASS: Lithos block $found carries the client's genesis and its upkeep beat"; rig_verdict=PASS
else fail "no Lithos block carrying a beat within 30 minutes"; fi
companion_stop client; companion_stop proxy; companion_stop miner
