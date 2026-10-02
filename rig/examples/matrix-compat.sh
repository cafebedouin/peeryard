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
DUR=${MATRIX_COMPAT_S:-480}
MINERS=$(jq -r '(.compat_miners // []) | join(" ")' "$CFG")
echo "[matrix-compat] nodes: $(for x in "${NODES[@]}"; do printf '%s=%s ' "$x" "$(rest "$x" /info | jq -r .appVersion)"; done)miners: $MINERS"
for _ in $(seq 1 120); do
  ha=$(full_height A); ok=1; for x in "${NODES[@]}"; do [[ "$(full_height "$x")" == "$ha" ]] || ok=0; done
  [[ -n "$ha" && "$ha" -ge 20 && $ok == 1 ]] && break; sleep 5
done
H0=$(full_height A); echo "[matrix-compat] joined at A.h=$H0"
for x in $MINERS; do [[ "$x" == A ]] || start_mining "$x" 500ms; done
MARK=$(date +%H:%M:%S); echo "[matrix-compat] all miners mining from $MARK"
for i in $(seq 1 $((DUR / 20))); do sleep 20
  line="t=$((i * 20))s"; for x in "${NODES[@]}"; do line+=" $x.h=$(full_height "$x") $x.tip=$(rest "$x" /blocks/lastHeaders/1 | jq -r '.[0].id[:8]')"; done
  echo "[matrix-compat] $line"
done
# stop every miner, then let the network settle before comparing: tips compared while several nodes mine race.
# The analysis window ends here, before the relaunches (a restart brings its own reconnects and penalties).
END=$(date +%H:%M:%S)
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
