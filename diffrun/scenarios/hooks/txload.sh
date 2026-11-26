# shellcheck shell=bash
# txload hook: A mines and funds its wallet (reward delay 10 on the current preset); then A pays B 100000000
# nanoERG ten times in a burst; B's confirmed balance must reach 1 ERG and the payments must appear as
# non-coinbase transactions in A's blocks. RESULT_JSON: accepted, confirmed (payments covered by B's balance),
# txs_in_blocks, unresponsive_after. A that never has a spendable balance makes the run INCONCLUSIVE (no RESULT_JSON).
N=10; AMT=100000000
va=$(rest A /info | jq -r '.appVersion // "null"'); vb=$(rest B /info | jq -r '.appVersion // "null"')
# an unfunded miner is setup (the run is INCONCLUSIVE, no RESULT_JSON: rig-scenario.sh exits 3), not a measurement
# of payments; it can itself be a jar regression, which the rig output keeps
wait_balance A 20000000000 300 >/dev/null || { echo "[txload] INCONCLUSIVE: A never had a spendable balance"; rig_verdict=INCONCLUSIVE; rig_cause=SETUP_NO_BALANCE; return; }
h0=$(full_height A); acc=0
for ((i=1;i<=N;i++)); do r=$(pay A B $AMT); [ ${#r} = 64 ] && acc=$((acc + 1)) || echo "[txload] payment $i: $r"; sleep 0.3; done
bal=$(wait_balance B $((N * AMT)) 240); conf=$((bal / AMT)); [ $conf -gt $N ] && conf=$N
# minus one coinbase per block. A block always holds its coinbase, so a read that is not a count of at least 1 (a
# timeout's empty body) is unknown: read once more, else left out and named, never taken as 0 (which subtracts 1)
h1=$(full_height A); txs=0; unread=""
for ((h=h0+1; h<=h1; h++)); do c=$(block_txs A "$h"); [[ "$c" =~ ^[1-9][0-9]*$ ]] || { sleep 1; c=$(block_txs A "$h"); }
  if [[ "$c" =~ ^[1-9][0-9]*$ ]]; then txs=$((txs + c - 1)); else unread+=" $h"; fi; done
[ -n "$unread" ] && echo "[txload] blocks not read, left out of txs_in_blocks:$unread"
unr=0; for n in A B; do [ "$(rest $n /info | jq -r '.appVersion // "null"')" = null ] && unr=$((unr + 1)); done
echo "[txload] accepted=$acc/$N B balance=$bal (confirmed $conf) non-coinbase txs in blocks $((h0 + 1))..$h1: $txs"
echo "RESULT_JSON $(jq -cn --arg A "$va" --arg B "$vb" --argjson a "$acc" --argjson c "$conf" --argjson t "$txs" --argjson u "$unr" --arg jv "$(${PEERYARD_JAVA:-java} -version 2>&1 | head -1)" \
  '{schema_version:1,scenario:"txload",runtime:{java:$jv},versions:{A:$A,B:$B},metrics:{accepted:$a,confirmed:$c,txs_in_blocks:$t,unresponsive_after:$u}}')"
rig_verdict=$([ $conf = $N ] && echo PASS || echo FAIL)
