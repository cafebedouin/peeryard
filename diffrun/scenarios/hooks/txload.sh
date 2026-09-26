# shellcheck shell=bash
# txload hook: A mines and funds its wallet (reward delay 10 on the current preset); then A pays B 100000000
# nanoERG ten times in a burst; B's confirmed balance must reach 1 ERG and the payments must appear as
# non-coinbase transactions in A's blocks. RESULT_JSON: accepted, confirmed (payments covered by B's balance),
# txs_in_blocks, unresponsive_after.
N=10; AMT=100000000
va=$(rest A /info | jq -r '.appVersion // "null"'); vb=$(rest B /info | jq -r '.appVersion // "null"')
wait_balance A 20000000000 300 >/dev/null || echo "[txload] A never had a spendable balance"
h0=$(full_height A); acc=0
for ((i=1;i<=N;i++)); do r=$(pay A B $AMT); [ ${#r} = 64 ] && acc=$((acc + 1)) || echo "[txload] payment $i: $r"; sleep 0.3; done
bal=$(wait_balance B $((N * AMT)) 240); conf=$((bal / AMT)); [ $conf -gt $N ] && conf=$N
h1=$(full_height A); txs=0; for ((h=h0+1; h<=h1; h++)); do c=$(block_txs A $h); txs=$((txs + c - 1)); done
unr=0; for n in A B; do [ "$(rest $n /info | jq -r '.appVersion // "null"')" = null ] && unr=$((unr + 1)); done
echo "[txload] accepted=$acc/$N B balance=$bal (confirmed $conf) non-coinbase txs in blocks $((h0 + 1))..$h1: $txs"
echo "RESULT_JSON $(jq -cn --arg A "$va" --arg B "$vb" --argjson a "$acc" --argjson c "$conf" --argjson t "$txs" --argjson u "$unr" --arg jv "$(${PEERYARD_JAVA:-java} -version 2>&1 | head -1)" \
  '{schema_version:1,scenario:"txload",runtime:{java:$jv},versions:{A:$A,B:$B},metrics:{accepted:$a,confirmed:$c,txs_in_blocks:$t,unresponsive_after:$u}}')"
rig_verdict=$([ $conf = $N ] && echo PASS || echo FAIL)
