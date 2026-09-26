# matrix-latency: input blocks across two slow hops. Three Matrix-line nodes in a line, A - B - C, each link with
# 150 ms delay and 100 ms jitter (netem reorders packets under jitter, so input blocks can reach a node
# descendant-first). A mines; B relays; C is two hops away. Every MATRIX_SAMPLE_S seconds the hook records C's
# input chain against A's (same_input_chain_stable) and counts the distinct input-block ids C reports.
#   PEERYARD_MATRIX_JAR=<weak-blocks jar> bash rig/rig.sh rig/examples/matrix-latency.json rig/examples/matrix-latency.sh
#   PEERYARD_DURATION seconds to observe (default 300); MATRIX_SAMPLE_S (default 20)
# PASS = C reported input blocks (they cross two hops), C's input chain matched A's or was a prefix of it at the end
# (never a different chain), A and C agree by header id and, with A paused, by state root, and the peer sets match
# the topology. Samples where C's input chain differed from A's (an input-block fork at C) are counted and reported.
DUR=${PEERYARD_DURATION:-300}; SAMPLE=${MATRIX_SAMPLE_S:-20}; nc=0; ndiff=0; nsame=0; nprefix=0
declare -A SEEN_C SEEN_B; nb=0
t0=$SECONDS
while [ $((SECONDS - t0)) -lt "$DUR" ]; do
  sleep "$SAMPLE"
  for id in $(input_chain_ids C); do [ -z "${SEEN_C[$id]:-}" ] && { SEEN_C[$id]=1; nc=$((nc + 1)); }; done
  ic=$(same_input_chain_stable A C 20)
  case "$ic" in SAME@*) nsame=$((nsame + 1)) ;; PREFIX@*) nprefix=$((nprefix + 1)) ;; DIFF@*) ndiff=$((ndiff + 1)) ;; esac
  for id in $(input_chain_ids B); do [ -z "${SEEN_B[$id]:-}" ] && { SEEN_B[$id]=1; nb=$((nb + 1)); }; done
  echo "  t+$((SECONDS - t0))s A.h=$(full_height A) B.h=$(full_height B) C.h=$(full_height C) input_chain(A,B)=$(same_input_chain_stable A B 10) input_chain(A,C)=$ic B.input_seen=$nb C.input_seen=$nc"
done
icf=$(same_input_chain_stable A C); sc=$(same_chain A C)
stop_mining A >/dev/null
st=NOHEIGHT; for _ in $(seq 1 30); do st=$(same_state A C); case "$st" in SAME@*|DIFF@*) break ;; esac; sleep 2; done
echo "[matrix-latency] samples: same=$nsame prefix=$nprefix diff=$ndiff; input blocks seen by B: $nb, by C: $nc; end: input_chain=$icf same_chain=${sc%%:*} same_state=${st%%:*}"
echo "[matrix-latency] peers vs topology:"; check_topology_wait && topo=ok || topo=mismatch
res=FAIL
case "$icf" in SAME@*|PREFIX@*) icok=yes ;; *) icok=no ;; esac
if [ "$nc" -ge 1 ] && [ "$icok" = yes ] && [ "${sc%%@*}" = SAME ] && [ "${st%%@*}" = SAME ] && [ "$topo" = ok ]; then res=PASS; fi
rig_verdict=$res; echo "[matrix-latency] === MATRIX-LATENCY: $res ==="; echo "MATRIX-LATENCY-DONE"
