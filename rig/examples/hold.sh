# hold: keep the network up until told to stop (used by rig/devnet.sh). Prints the node table, then waits for
# $SCRATCH/stop to appear. Nothing is measured; rig_verdict stays PASS so `down` exits 0.
echo "[hold] devnet up; nodes:"
for n in "${NODES[@]}"; do printf '  %-4s ip=%s rest=127.0.0.1:%s (inside ns_%s) jar=%s\n' "$n" "$(node_ip "$n")" "${REST[$n]}" "$n" "$(basename "${NODE_JAR[$n]}")"; done
echo "[hold] stop with: touch $SCRATCH/stop   (or rig/devnet.sh down)"
while [[ ! -e "$SCRATCH/stop" ]]; do sleep 5; done
echo "[hold] stop requested; heights: $(for n in "${NODES[@]}"; do printf '%s=%s ' "$n" "$(full_height "$n")"; done)"
rig_verdict=PASS
echo "HOLD-DONE"
