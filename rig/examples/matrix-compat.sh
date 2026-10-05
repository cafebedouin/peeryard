# matrix-compat: shared hook for the matrix-compat-* examples (each example's .sh sources this file). A network of Matrix
# nodes (ergo's weak-blocks line, PEERYARD_MATRIX_JAR) and/or reference nodes (PEERYARD_JAR), topology and miners set in
# the example's .json: "compat_miners" (the nodes that mine), "compat_kinds" ({name: "M" | "R"}). A mines from the start;
# every other node joins A's chain as a follower, then the named miners switch mining on (joining first keeps them off a
# chain of their own); then MATRIX_COMPAT_S (480) seconds of mining, sampled every 20 s. Meant for block version 4
# (PEERYARD_V4=1 or the workflows' v4 input), the regime a Matrix release runs.
# At the end diag/matrix_compat.py reads the node logs: relay among Matrix nodes, ordering blocks and reorgs, input-chain
# rollbacks, peer penalties (by who penalized whom), and ban / blacklist lines.
# PASS = after mining stops and the network settles (every node's best header and best full block equal A's, up to
# 120 s), every node is on A's chain and state (same_chain and same_state SAME@h against A) and no node logged a ban or
# blacklist line during the mining window. Relay, rollbacks and penalties are reported, not judged (peers on an all-Matrix
# network penalize each other too: compare a mixed topology with matrix-compat-m2..m4).
# Optional, both off by default (the run is then exactly as before):
#   MATRIX_COMPAT_TXLOAD=<n>  a benign payment load during the window (rig/lib/txload.sh): n payments per 10 s on
#     average among every node's wallet (A first funds the others with MATRIX_COMPAT_TXLOAD_FUND nanoERG each, default
#     20 ERG), about 30% of ticks a chain of 3 back-to-back payments from one wallet (later ones may spend unconfirmed
#     change); the load stops MATRIX_COMPAT_TXLOAD_DRAIN_S (60) s before the window ends, the pools are read at its end
#     and diag/txload_report.py prints MATRIX-TXLOAD (per payment: submit time, node, id, first input block seen,
#     holding ordering block, lost or not; txrecords.jsonl). Reported, not judged.
#   PEERYARD_EXTMINE_POLL=<1s|4s|...>  (rig.sh) every miner is an external miner polling /mining/candidate at that
#     interval instead of the node's internal CPU miner; MATRIX-EXTMINE sums each miner's submissions.
#     PEERYARD_EXTMINE_STRICT=1: those miners read the candidate only on the poll schedule (extminer.py --strict).
DUR=${MATRIX_COMPAT_S:-480}
TXL=${MATRIX_COMPAT_TXLOAD:-0}; TXL_DRAIN=${MATRIX_COMPAT_TXLOAD_DRAIN_S:-60}; TXL_FUND=${MATRIX_COMPAT_TXLOAD_FUND:-20000000000}
[[ "$TXL" =~ ^[0-9]+$ && $TXL -le 50 ]] || { echo "[matrix-compat] MATRIX_COMPAT_TXLOAD '$TXL': 0-50 payments per 10 s"; rig_verdict=INCONCLUSIVE; return; }
MINERS=$(jq -r '(.compat_miners // []) | join(" ")' "$CFG")
echo "[matrix-compat] nodes: $(for x in "${NODES[@]}"; do printf '%s=%s ' "$x" "$(rest "$x" /info | jq -r .appVersion)"; done)miners: $MINERS"
for _ in $(seq 1 120); do
  ha=$(full_height A); ok=1; for x in "${NODES[@]}"; do [[ "$(full_height "$x")" == "$ha" ]] || ok=0; done
  [[ -n "$ha" && "$ha" -ge 20 && $ok == 1 ]] && break; sleep 5
done
H0=$(full_height A); echo "[matrix-compat] joined at A.h=$H0"
# MATRIX_COMPAT_POLL: the miners' candidate poll interval (default 500ms); a slow poll without candidate push stands in for
# external miners and pools, which poll /mining/candidate every few seconds. A follows PEERYARD_MINE_POLL (set both).
for x in $MINERS; do [[ "$x" == A ]] || start_mining "$x" "${MATRIX_COMPAT_POLL:-500ms}"; done
# MATRIX_COMPAT_WARMUP_H=<h> (default 0 = off, the window starts as before): the miners mine until A's full height
# reaches h, and the window (MARK, the payment load, the analysis) starts only then, so it skips the devnet's start-up
# difficulty ramp (initial difficulty 1, retarget every 16 blocks over the last 8 epochs). Use it with the rig's
# PEERYARD_NO_DIFF_RESET=1, or the window meets the forced difficulty 32 at heights 128-144. The per-height table below
# still starts at the join height; "[matrix-compat] window from A.h=" names the window's first height.
WARM=${MATRIX_COMPAT_WARMUP_H:-0}
[[ "$WARM" =~ ^[0-9]{1,4}$ ]] || { echo "[matrix-compat] MATRIX_COMPAT_WARMUP_H '$WARM': a height (0 = off)"; rig_verdict=INCONCLUSIVE; return; }
if (( WARM > 0 )); then
  echo "[matrix-compat] warm-up: all miners mining from $(date +%H:%M:%S) at A.h=$(full_height A); window starts at A.h>=$WARM"
  wend=$((SECONDS + ${MATRIX_COMPAT_WARMUP_MAX_S:-3600}))
  while :; do hw=$(full_height A); [[ -n "$hw" && "$hw" -ge $WARM ]] && break
    (( SECONDS >= wend )) && { echo "[matrix-compat] warm-up: A.h=${hw:-?} after ${MATRIX_COMPAT_WARMUP_MAX_S:-3600} s, below $WARM"; rig_verdict=INCONCLUSIVE; return; }
    sleep 2; done
fi
MARK=$(date +%H:%M:%S); echo "[matrix-compat] all miners mining from $MARK"
echo "[matrix-compat] window from A.h=$(full_height A)"
if (( TXL > 0 )); then
  others=(); for x in "${NODES[@]}"; do [[ "$x" == A ]] || others+=("$x"); done
  txwatch_start "${NODES[@]}"; txload_fund A "$TXL_FUND" "${others[@]}"; txload_start "$TXL" "${NODES[@]}"
fi
for i in $(seq 1 $((DUR / 20))); do sleep 20
  (( TXL > 0 && i * 20 >= DUR - TXL_DRAIN )) && txload_stop
  line="t=$((i * 20))s"; for x in "${NODES[@]}"; do line+=" $x.h=$(full_height "$x") $x.tip=$(rest "$x" /blocks/lastHeaders/1 | jq -r '.[0].id[:8]')"; done
  echo "[matrix-compat] $line"
done
# stop every miner, then let the network settle before comparing: tips compared while several nodes mine race.
# The analysis window ends here, before the relaunches (a restart brings its own reconnects and penalties).
END=$(date +%H:%M:%S)
if (( TXL > 0 )); then txload_stop; txwatch_stop; txload_pools "${NODES[@]}"; fi   # pools before the relaunches empty them
# each miner's reward key, read while it still mines (the mining routes answer only with mining on)
declare -A PKN; for x in $MINERS; do pk=$(rest "$x" /mining/rewardPublicKey | jq -r '.rewardPubkey // empty'); [[ -n "$pk" ]] && PKN[$pk]=$x; done
echo "[matrix-compat] reward keys read for ${#PKN[@]} of $(wc -w <<< "$MINERS") miners"
for x in $MINERS; do stop_mining "$x"; done
# settled = every node's best header and best full block are A's (headers alone agree before the restarted nodes have
# applied the blocks, which is a lag, not a divergence); up to 120 s, so a real non-convergence is still reported
settled=0
for _ in $(seq 1 24); do
  ref=$(rest A /info | jq -r '"\(.bestHeaderId)/\(.bestFullHeaderId)"'); ok=1
  [[ "$ref" == */* && "${ref%/*}" == "${ref#*/}" ]] || ok=0
  for x in "${NODES[@]}"; do [[ "$(rest "$x" /info | jq -r '"\(.bestHeaderId)/\(.bestFullHeaderId)"')" == "$ref" ]] || ok=0; done
  [[ $ok == 1 ]] && { settled=1; break; }; sleep 5
done
echo "[matrix-compat] mining stopped; $( [[ $settled == 1 ]] && echo 'every node has the same best header and full block' || echo 'best header or full block still differ after 120 s')"
# per-height miner and difficulty on A's final chain, for every height mined in the window (the window's totals above
# count every block a node mined, stale ones included; this table is the chain as it ended)
tip=$(full_height A)
for ((h = H0 + 1; h <= tip; h++)); do
  id=$(rest A "/blocks/at/$h" | jq -r '.[0] // empty'); [[ -z "$id" ]] && { echo "[matrix-compat] height $h miner ? difficulty ?"; continue; }
  hd=$(rest A "/blocks/$id/header")
  pk=$(jq -r '.powSolutions.pk' <<< "$hd"); echo "[matrix-compat] height $h miner ${PKN[$pk]:-?} difficulty $(jq -r '.difficulty' <<< "$hd")"
done
if (( TXL > 0 )); then txload_chain A "$H0"
  python3 "$(dirname "$(readlink -f "$HOOK")")/../../diag/txload_report.py" "$RIG_LOG_DIR" 2>&1 || echo "[matrix-compat] txload report failed"; fi
if [[ -n "${EXTMINE_POLL:-}" ]]; then for x in $MINERS; do
  f="$RIG_LOG_DIR/extminer_$x.log"; [[ -f "$f" ]] || { echo "MATRIX-EXTMINE $x no-log"; continue; }
  # each miner process prints EXTMINER-SUMMARY when stopped (stop_mining above); a node mined by more than one process sums them
  awk -v n="$x" '/ EXTMINER-SUMMARY /{for(i=3;i<=NF;i++){split($i,kv,"="); if(kv[1]!="poll_s" && kv[1]!="rate" && kv[1]!="strict") s[kv[1]]+=kv[2]; else o[kv[1]]=kv[2]} c++}
    END{printf "MATRIX-EXTMINE %s processes=%d", n, c; for(k in s) printf " %s=%d", k, s[k]; printf " poll_s=%s rate=%s strict=%s\n", o["poll_s"], o["rate"], (o["strict"]==""?0:o["strict"])}' "$f"
done; fi
res=PASS
for x in "${NODES[@]}"; do [[ "$x" == A ]] && continue
  sc=$(same_chain A "$x"); ss=$(same_state A "$x"); echo "[matrix-compat] A-$x same_chain=${sc:0:24} same_state=${ss:0:24}"
  [[ "$sc" == SAME@* && "$ss" == SAME@* ]] || res=FAIL
done
out=$(python3 "$(dirname "$(readlink -f "$HOOK")")/../../diag/matrix_compat.py" "$RIG_LOG_DIR" "$CFG" "$MARK" "$END" 2>&1) || out="[matrix-compat] analysis failed: ${out:0:300}"
echo "$out"
bans=$(sed -n 's/^MATRIX-COMPAT-BANS //p' <<< "$out"); [[ "${bans:-x}" == 0 ]] || res=FAIL
rig_verdict=$res
echo "MATRIX-COMPAT: $res"
