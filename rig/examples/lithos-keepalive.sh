# lithos-keepalive: the Lithos client's KeepAlive upkeep job against a devnet, end to end. One indexed mining node A
# (v4, 20 s blocks, zero mempool fee floor), as lithos-upkeep. The hook compiles a KeepAlive receive address
# (skunkyard skunks/keepalive/KeepAliveAddress.es, devnet terms: PERIOD 40, WINDOW 20, PER_INPUT 0.0005 ERG, REFRESH
# 0.002 ERG, SLACK 10) for A's own wallet key, issues a token, and pays the address three times from A's wallet as
# any payer would (no registers): 0.05 ERG + 1 unit, 0.001 ERG + 2 units, 0.001 ERG + 3 units. Then it starts the
# appkit proxy and the client with only the keepalive job on, and waits for the client to merge the three boxes.
# PASS = one box left at the address, holding all 6 units and 0.0505 ERG (0.052 less the bounty, min(3 x 0.0005,
# 0.052 - 0.05) = 0.0015 ERG), with the three payments spent.
#
# Needs: LITHOS_STAGE (the client's staged distribution, built from the upkeep-keepalive branch), LITHOS_CONF (a client
# config as lithos-upkeep's, with jobs.keepalive { enabled = true, minBounty = 0 } and the heartbeat off), KAA_SOURCE
# (the path to KeepAliveAddress.es), JAVA_HOME at 17.
: "${LITHOS_STAGE:?the staged client distribution directory}"; : "${LITHOS_CONF:?the client config file}"
: "${KAA_SOURCE:?the path to KeepAliveAddress.es}"
HERE_LIB="$(cd "$(dirname "$RIG_HOOK")/../lib" && pwd)"
JAVA_HOME="${JAVA_HOME:-/usr/lib/jvm/java-17-openjdk-amd64}"
PROXY_PORT=${PROXY_PORT:-9153}; WD="$SCRATCH/lithos"; mkdir -p "$WD"; CHECKS="$WD/checks.jsonl"; : > "$CHECKS"
rig_verdict=FAIL
fail(){ echo "[lk] FAIL: $*"; return 0 2>/dev/null || exit 0; }
# 1. block version 4 and a funded wallet
end=$((SECONDS + 600)); bv=""
while [[ $SECONDS -lt $end ]]; do bv=$(rest A /info | jq -r '.parameters.blockVersion // empty'); [[ "$bv" == 4 ]] && break; sleep 10; done
[[ "$bv" == 4 ]] || { fail "block version 4 did not activate"; return 0 2>/dev/null || exit 0; }
bal=$(wait_balance A 2000000000 300) || { fail "A's wallet never reached 2 ERG ($bal)"; return 0 2>/dev/null || exit 0; }
# 2. the address, compiled by A for A's key
# Retried: just after start-up the node's readers can time out (HTTP 500, "Ask timed out … GetReaders")
OWNER_ADDR=""; PK=""; end=$((SECONDS + 180))
while [[ -z "$PK" && $SECONDS -lt $end ]]; do
  OWNER_ADDR=$(address A); [[ -n "$OWNER_ADDR" ]] && PK=$(rest A "/utils/addressToRaw/$OWNER_ADDR" | jq -r '.raw // empty' 2>/dev/null)
  [[ -n "$PK" ]] || sleep 5; done
[[ -n "$PK" ]] || { fail "A's wallet address could not be read"; return 0 2>/dev/null || exit 0; }
SRC=$(python3 - "$KAA_SOURCE" "$PK" <<'EOF'
import json, sys
s = open(sys.argv[1]).read()
for k, v in dict(OWNER=sys.argv[2], PERIOD="40", WINDOW="20", PER_INPUTL="500000L", REFRESHL="2000000L", SLACK="10").items():
    s = s.replace("$" + k, v)
print(json.dumps({"source": s, "treeVersion": 1}))
EOF
)
VAULT=""; end=$((SECONDS + 120))
while [[ -z "$VAULT" && $SECONDS -lt $end ]]; do
  resp=$(wallet A /script/p2sAddress "$SRC"); VAULT=$(jq -r '.address // empty' <<<"$resp" 2>/dev/null); [[ -n "$VAULT" ]] || sleep 5; done
[[ -n "$VAULT" ]] || { fail "A did not compile the address: ${resp:0:300}"; return 0 2>/dev/null || exit 0; }
TREE=$(rest A "/script/addressToTree/$VAULT" | jq -r .tree); echo "$TREE" > "$WD/vault.tree"
echo "[lk] KeepAlive address for A's key $PK: ${VAULT:0:24}… ($(( ${#TREE} / 2 )) bytes)"
at_vault(){ ip netns exec "${NS[A]}" curl -s --max-time 10 -X POST -H 'Content-Type: application/json' \
  "http://127.0.0.1:${REST[A]}/blockchain/box/unspent/byErgoTree" --data "\"$TREE\""; }
mined(){ local t="$1" end=$((SECONDS + 240)); while [[ $SECONDS -lt $end ]]; do
  [[ "$(rest A "/blockchain/transaction/byId/$t" | jq -r '.inclusionHeight // empty')" != "" ]] && return 0; sleep 5; done; return 1; }
# 3. a token, then three plain payments to the address. Sends get their own helper: the rig's wallet() gives up after
# 10 s, and a send on a node just started can take longer; a transaction id (64 hex) must come back, or it retries.
send(){ local body="$1" out="" end=$((SECONDS + 180))
  while [[ $SECONDS -lt $end ]]; do
    out=$(ip netns exec "${NS[A]}" curl -s --max-time 60 -X POST -H "api_key: $API_KEY" -H 'Content-Type: application/json' \
      --data "$body" "http://127.0.0.1:${REST[A]}/wallet/transaction/send" | jq -r 'if type=="string" then . else empty end' 2>/dev/null)
    [[ "$out" =~ ^[0-9a-f]{64}$ ]] && { echo "$out"; return 0; }; sleep 5; done; return 1; }
itx=$(send "{\"requests\":[{\"address\":\"$OWNER_ADDR\",\"ergValue\":1000000,\"amount\":6,\"name\":\"KAA\",\"description\":\"keepalive rig\",\"decimals\":0}],\"fee\":1000000}")
mined "$itx" || { fail "the token issue $itx was not mined"; return 0 2>/dev/null || exit 0; }
TOKEN=$(rest A "/blockchain/transaction/byId/$itx" | jq -r '.outputs[0].assets[0].tokenId')
ptx=$(send "{\"requests\":[
  {\"address\":\"$VAULT\",\"value\":50000000,\"assets\":[{\"tokenId\":\"$TOKEN\",\"amount\":1}]},
  {\"address\":\"$VAULT\",\"value\":1000000,\"assets\":[{\"tokenId\":\"$TOKEN\",\"amount\":2}]},
  {\"address\":\"$VAULT\",\"value\":1000000,\"assets\":[{\"tokenId\":\"$TOKEN\",\"amount\":3}]}],\"fee\":1000000}")
mined "$ptx" || { fail "the payments $ptx were not mined"; return 0 2>/dev/null || exit 0; }
n=0; end=$((SECONDS + 120)); while [[ $SECONDS -lt $end ]]; do n=$(at_vault | jq 'length'); [[ "$n" == 3 ]] && break; sleep 5; done
[[ "$n" == 3 ]] || { fail "the index lists $n boxes at the address, not 3"; return 0 2>/dev/null || exit 0; }
echo "[lk] token $TOKEN; three payments at the address (tx $ptx), height $(full_height A)"
# 4. the proxy and the client, inside A's namespace
companion_start proxy --in A -- python3 "$HERE_LIB/appkit-proxy.py" --listen "127.0.0.1:$PROXY_PORT" \
  --upstream "http://127.0.0.1:${REST[A]}" --record-checks "$CHECKS" --mirror; sleep 2
cd "$WD"; companion_start client --in A -- env JAVA_HOME="$JAVA_HOME" PATH="$JAVA_HOME/bin:$PATH" \
  "$LITHOS_STAGE/bin/lithos-client" -Dconfig.file="$LITHOS_CONF" -Dhttp.port=9100 -Dpidfile.path=/dev/null; cd - >/dev/null
CLIENT_LOG="$(companion_log client)"
# 5. the merge, accepted by the node's check, then mined
end=$((SECONDS + 600)); ok=no
while [[ $SECONDS -lt $end ]]; do grep -qE "after the node's check: keepalive" "$CLIENT_LOG" && { ok=yes; break; }; sleep 10; done
grep -E "Upkeep" "$CLIENT_LOG" | grep -v "^\s*at " | tail -6 | cut -c1-200
if [[ $ok != yes ]]; then fail "the client never had a merge accepted by the node's check"
else
  end=$((SECONDS + 300)); one=""
  while [[ $SECONDS -lt $end ]]; do sleep 10; [[ "$(at_vault | jq 'length')" == 1 ]] && { one=yes; break; }; done
  box=$(at_vault | jq -c --arg t "$TOKEN" '.[0] | {boxId, value, creationHeight, units: ([.assets[] | select(.tokenId==$t) | .amount] | add)}')
  echo "[lk] at the address now: $box"
  if [[ "$one" == yes ]] && [[ "$(jq -r .units <<<"$box")" == 6 ]] && [[ "$(jq -r .value <<<"$box")" == 50500000 ]]; then
    echo "[lk] checks recorded: $(wc -l < "$CHECKS"); mirrored: $(grep -c 'mirrored to mempool' "$(companion_log proxy)")"
    echo "[lk] PASS: the client merged the three payments into one box, every unit kept, the bounty paid"; rig_verdict=PASS
  else fail "expected one box with 6 units and 50500000 nanoERG"; fi
fi
companion_stop client; companion_stop proxy
