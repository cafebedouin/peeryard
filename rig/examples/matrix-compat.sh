# matrix-compat: shared hook for the matrix-compat-* examples (each example's .sh sources this file). A network of Matrix
# nodes (ergo's weak-blocks line, PEERYARD_MATRIX_JAR) and/or reference nodes (PEERYARD_JAR), topology and miners set in
# the example's .json: "compat_miners" (the nodes that mine), "compat_kinds" ({name: "M" | "R"}). A mines from the start;
# every other node joins A's chain as a follower, then the named miners switch mining on (joining first keeps them off a
# chain of their own); then MATRIX_COMPAT_S (480) seconds of mining, sampled every 20 s. Meant for block version 4
# (PEERYARD_V4=1 or the workflows' v4 input), the regime a Matrix release runs.
# At the end diag/matrix_compat.py reads the node logs: relay among Matrix nodes, ordering blocks and reorgs, input-chain
# rollbacks, peer penalties (by who penalized whom), and ban / blacklist lines.
# PASS = every node ends on A's chain and state (same_chain and same_state SAME@h against A) and no node logged a ban or
# blacklist line during the mining window. Relay, rollbacks and penalties are reported, not judged (peers on an all-Matrix
# network penalize each other too: compare a mixed topology with matrix-compat-m2..m4).
DUR=${MATRIX_COMPAT_S:-480}
MINERS=$(jq -r '(.compat_miners // []) | join(" ")' "$CFG")
echo "[matrix-compat] nodes: $(for x in "${NODES[@]}"; do printf '%s=%s ' "$x" "$(rest "$x" /info | jq -r .appVersion)"; done)miners: $MINERS"
for _ in $(seq 1 120); do
  ha=$(full_height A); ok=1; for x in "${NODES[@]}"; do [[ "$(full_height "$x")" == "$ha" ]] || ok=0; done
  [[ -n "$ha" && "$ha" -ge 20 && $ok == 1 ]] && break; sleep 5
done
echo "[matrix-compat] joined at A.h=$(full_height A)"
for x in $MINERS; do [[ "$x" == A ]] || start_mining "$x" 500ms; done
MARK=$(date +%H:%M:%S); echo "[matrix-compat] all miners mining from $MARK"
for i in $(seq 1 $((DUR / 20))); do sleep 20
  line="t=$((i * 20))s"; for x in "${NODES[@]}"; do line+=" $x.h=$(full_height "$x") $x.tip=$(rest "$x" /blocks/lastHeaders/1 | jq -r '.[0].id[:8]')"; done
  echo "[matrix-compat] $line"
done
res=PASS
for x in "${NODES[@]}"; do [[ "$x" == A ]] && continue
  sc=$(same_chain A "$x"); ss=$(same_state A "$x"); echo "[matrix-compat] A-$x same_chain=${sc:0:24} same_state=${ss:0:24}"
  [[ "$sc" == SAME@* && "$ss" == SAME@* ]] || res=FAIL
done
out=$(python3 "$(dirname "$(readlink -f "$HOOK")")/../../diag/matrix_compat.py" "$RIG_LOG_DIR" "$CFG" "$MARK" 2>&1) || out="[matrix-compat] analysis failed: ${out:0:300}"
echo "$out"
bans=$(sed -n 's/^MATRIX-COMPAT-BANS //p' <<< "$out"); [[ "${bans:-x}" == 0 ]] || res=FAIL
rig_verdict=$res
echo "MATRIX-COMPAT: $res"
