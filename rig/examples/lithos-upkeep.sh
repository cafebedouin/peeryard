# lithos-upkeep: the Lithos client's upkeep source against a devnet, end to end. One indexed mining node A at block
# version 4 with 20 s blocks and a zero mempool fee floor. The hook funds a due-job box (the client's reference
# contract, DueJob.ergo: R4 last beat, R5 period, R6 tip) from A's wallet, starts the appkit proxy and the Lithos client
# inside A's namespace, and waits for the client to discover the box through the index, build its beat, have the
# node's check accept it, and for the beat to be mined by A (the proxy mirrors each accepted check into the mempool
# inside the same height, because a beat is valid in exactly one block). PASS = a successor box at the script with R4
# advanced to a later height than the one funded.
#
# Needs: LITHOS_STAGE (the client's staged distribution, `sbt stage` -> target/universal/stage), LITHOS_CONF (a client
# config whose node.url is http://127.0.0.1:9153, node.networkType TESTNET, node.key hello, a keystore and its
# password, upkeep enabled in candidate mode with verifyWithNode and the heartbeat job on), JAVA_HOME at 17.
# Without a Lithos deployment on the chain the client builds no genesis transaction and never assembles a package;
# what this hook proves is the source's own path: discovery, build, the node's check, and consensus validity of the
# beat. The deployment and the package are the next hook.
: "${LITHOS_STAGE:?the staged client distribution directory}"; : "${LITHOS_CONF:?the client config file}"
HERE_LIB="$(cd "$(dirname "$RIG_HOOK")/../lib" && pwd)"
JAVA_HOME="${JAVA_HOME:-/usr/lib/jvm/java-17-openjdk-amd64}"
PROXY_PORT=${PROXY_PORT:-9153}; WD="$SCRATCH/lithos"; mkdir -p "$WD"; CHECKS="$WD/checks.jsonl"; : > "$CHECKS"
TREE=1b8f01040400040005000400d804d601e4c6a70504d602e4c6a70605d603b2a5730000d604c1a7d1edededededededededed9172017301927202730293c5b2a4730300c5a7927ea3059a7ee4c6a70404057e72010593c27203c2a793db63087203db6308a793e4c672030404a3938cc7720301a393e4c672030504720193e4c672030605720292c17203997204a172027204
ADDR=BLeBj4M5DTjaKjyEUwPF8JE7b6E4haYuHXwms5Rhf7mCThPdAnTdwPBHVTugWGXSgRzyt156JiWMSp31zuw3J3Vagvw1XGHQf1K7AUULYm64u8yWm6qVNpBQ3vBUWZS3tBkAExSYVFWz54M38YaZbVPLnPUx9HMNpnPiqzTz6Si1AQCPKUXUJS14aCTFc4TfF6RiqeEn2jUfHp
sint(){ python3 -c '
import sys; n=int(sys.argv[1]); z=((n<<1)^(n>>31))&0xffffffff; out=[]
while True:
  b=z&0x7f; z>>=7
  if z: out.append(b|0x80)
  else: out.append(b); break
print("04"+"".join("%02x"%b for b in out))' "$1"; }
boxes_at_tree(){ ip netns exec "${NS[A]}" curl -s --max-time 10 -X POST -H 'Content-Type: application/json' \
  "http://127.0.0.1:${REST[A]}/blockchain/box/unspent/byErgoTree" --data "\"$TREE\""; }
in_a(){ ip netns exec "${NS[A]}" "$@"; }
rig_verdict=FAIL
# 1. block version 4 (the contract is an ErgoTree v3 script)
end=$((SECONDS + 600)); bv=""
while [[ $SECONDS -lt $end ]]; do bv=$(rest A /info | jq -r '.parameters.blockVersion // empty'); [[ "$bv" == 4 ]] && break; sleep 10; done
[[ "$bv" == 4 ]] || { echo "[lu] FAIL: block version 4 did not activate"; return 0 2>/dev/null || exit 0; }
bal=$(wait_balance A 2000000000 300) || { echo "[lu] FAIL: A's wallet never reached 2 ERG ($bal)"; return 0 2>/dev/null || exit 0; }
# 2. the proxy inside A's namespace, mirroring accepted checks into A's mempool
in_a python3 "$HERE_LIB/appkit-proxy.py" --listen "127.0.0.1:$PROXY_PORT" --upstream "http://127.0.0.1:${REST[A]}" \
  --record-checks "$CHECKS" --mirror > "$WD/proxy.log" 2>&1 & PROXY_PID=$!; sleep 2
# 3. a due-job box, due at once: R4 ten blocks back, period 5, tip 0.01 ERG, 1 ERG
H=$(full_height A); R4=$(sint $((H - 10)))
tx=$(wallet A /wallet/transaction/send "{\"requests\":[{\"address\":\"$ADDR\",\"value\":1000000000,\"registers\":{\"R4\":\"$R4\",\"R5\":\"040a\",\"R6\":\"0580dac409\"}}],\"fee\":1000000}" | jq -r 'if type=="string" then . else (.detail // tojson) end')
echo "[lu] due-job box funded at height $H (R4=$((H-10)), period 5, tip 0.01 ERG): tx $tx"
BOX=""; end=$((SECONDS + 180))
while [[ -z "$BOX" && $SECONDS -lt $end ]]; do sleep 5; BOX=$(boxes_at_tree | jq -r '.[-1].boxId // empty' 2>/dev/null); done
[[ -n "$BOX" ]] || { echo "[lu] FAIL: the index never listed the due-job box"; kill $PROXY_PID; return 0 2>/dev/null || exit 0; }
echo "[lu] box $BOX listed by the index at height $(full_height A)"
# 4. the client, inside A's namespace so node.url = 127.0.0.1:$PROXY_PORT resolves to the proxy
( cd "$WD" && in_a env JAVA_HOME="$JAVA_HOME" PATH="$JAVA_HOME/bin:$PATH" "$LITHOS_STAGE/bin/lithos-client" \
    -Dconfig.file="$LITHOS_CONF" -Dhttp.port=9100 -Dpidfile.path=/dev/null > "$WD/client.log" 2>&1 ) & CLIENT_PID=$!
echo "[lu] client started (pid $CLIENT_PID), log $WD/client.log"
# 5. the client builds the beat and the node's check accepts it
end=$((SECONDS + 600)); ok=no
while [[ $SECONDS -lt $end ]]; do grep -qE "after the node's check: heartbeat" "$WD/client.log" && { ok=yes; break; }; sleep 10; done
grep -E "Upkeep" "$WD/client.log" | grep -v "^\s*at " | tail -6 | cut -c1-200
if [[ $ok != yes ]]; then echo "[lu] FAIL: the client never had a beat accepted by the node's check"
else
  # 6. the beat mined: the box at the script now carries a later R4 than the one funded
  end=$((SECONDS + 300)); adv=""
  while [[ -z "$adv" && $SECONDS -lt $end ]]; do sleep 10
    adv=$(boxes_at_tree | jq -r --arg r4 "$R4" '.[] | select(.additionalRegisters.R4 != $r4) | .boxId' 2>/dev/null | head -1); done
  if [[ -n "$adv" ]]; then
    echo "[lu] successor $adv at height $(full_height A): $(boxes_at_tree | jq -c --arg b "$adv" '.[] | select(.boxId==$b) | {value, R4: .additionalRegisters.R4, creationHeight}')"
    echo "[lu] checks recorded: $(wc -l < "$CHECKS"); mirrored: $(grep -c 'mirrored to mempool' "$WD/proxy.log")"
    echo "[lu] PASS: the client's beat was mined"; rig_verdict=PASS
  else echo "[lu] FAIL: no successor appeared within 300 s of the accepted check"; fi
fi
kill $CLIENT_PID $PROXY_PID 2>/dev/null; pkill -f "lithos-client" 2>/dev/null || true
