# matrix-churn: followers that leave and join while input chains are live. A mines on the Matrix line; B follows,
# crashes (the process is killed) while A keeps producing ordering and input blocks, and returns; C joins late
# (a deferred node's first launch) at the same moment. Both must catch up to A's ordering chain and to its current
# input chain (the input-tip sync a returning or new peer gets).
#   PEERYARD_MATRIX_JAR=<weak-blocks jar> bash rig/rig.sh rig/examples/matrix-churn.json rig/examples/matrix-churn.sh
#   MATRIX_DOWN_S how long B stays down (default 90)
# PASS = before the crash B matched A's input chain (SAME or prefix); after B's return and C's join both agree with
# A by header id, their input chains match A's or are a prefix of it, the state roots agree with A paused, and the
# peer sets match the topology. The catch-up times are reported.
DOWN=${MATRIX_DOWN_S:-90}; fail=0
follow(){ local f=$1 end=$((SECONDS + 300)) t0=$SECONDS; while [ $SECONDS -lt $end ]; do
  [ "$(same_chain A "$f" | cut -c1-4)" = SAME ] && [ $(( $(full_height A) - $(full_height "$f") )) -le 1 ] && { echo $((SECONDS - t0)); return 0; }; sleep 3; done; echo "-"; return 1; }
echo "[matrix-churn] phase 1: B follows A"; t=$(follow B) || fail=1; sleep 60
ic0=$(same_input_chain_stable A B); echo "[matrix-churn] B caught up in ${t} s; input chain before the crash: $ic0"
case "$ic0" in SAME@*|PREFIX@*) ;; *) fail=1 ;; esac
hdown=$(full_height A); echo "[matrix-churn] phase 2: B crashes at A.h=$hdown for ${DOWN}s"; crash B; sleep "$DOWN"
hup=$(full_height A)
echo "[matrix-churn] phase 3: B returns, C joins at A.h=$hup (A's input chain: $(input_chain_ids A | wc -l) blocks)"
# the premise: A kept producing while B was down, so B has a gap to catch up
if ! [ "${hup:-0}" -gt "${hdown:-0}" ] 2>/dev/null; then
  echo "[matrix-churn] INCONCLUSIVE: A did not advance while B was down ($hdown -> $hup)"; rig_verdict=INCONCLUSIVE; rig_cause=NO_PROGRESS_WHILE_DOWN
  echo "[matrix-churn] === MATRIX-CHURN: $rig_verdict ==="; echo "MATRIX-CHURN-DONE"; return 0
fi
revive B; launch C; wait_up C
tb=$(follow B) || fail=1; tc=$(follow C) || fail=1
icb=$(same_input_chain_stable A B); icc=$(same_input_chain_stable A C)
echo "[matrix-churn] B back on A's chain in ${tb} s, C in ${tc} s; input chain A,B=$icb A,C=$icc"
for r in "$icb" "$icc"; do case "$r" in SAME@*|PREFIX@*) ;; *) fail=1 ;; esac; done
stop_mining A >/dev/null
stb=NOHEIGHT; stc=NOHEIGHT; for _ in $(seq 1 30); do stb=$(same_state A B); stc=$(same_state A C)
  case "$stb/$stc" in SAME@*/SAME@*|DIFF@*/*|*/DIFF@*) break ;; esac; sleep 2; done
echo "[matrix-churn] same_state A,B=${stb%%:*} A,C=${stc%%:*}"
for r in "$stb" "$stc"; do case "$r" in SAME@*) ;; *) fail=1 ;; esac; done
echo "[matrix-churn] peers vs topology:"; check_topology_wait || fail=1
if [ $fail = 0 ]; then rig_verdict=PASS; else rig_verdict=FAIL; fi
echo "[matrix-churn] === MATRIX-CHURN: $rig_verdict ==="; echo "MATRIX-CHURN-DONE"
