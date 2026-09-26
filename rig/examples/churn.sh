# churn: nodes join late and leave while the chain moves. A mines with B following; C joins (a deferred node's
# first launch), then B leaves (crash) and D joins with B gone, then B comes back. At each step the live nodes
# must both stay on A's chain AND catch up to near its tip (a node that is on the chain but stuck far behind has
# not really rejoined), and at the end the connected-peer sets must match the topology's links. Every node knows
# all its link neighbours, so a revived node re-dials them rather than waiting to be dialled. PASS = every
# convergence step held and the peer check passes. Durations scale with PEERYARD_DURATION (default 300 s across
# the steps).
BUDGET=${PEERYARD_DURATION:-300}; STEP=$((BUDGET / 4)); LAG=4; fail=0
converge(){ # converge <label> <node>...: all listed nodes on A's chain (same_chain) and caught up to within LAG
  # of A's height, within STEP seconds. same_state is reported; LAG@.. same-chain (heights differ under a live
  # miner) is fine; DIFF@ (equal height, different root) and LAG@.. fork (the lower node's tip is not on A's chain) fail.
  local label=$1; shift; local end=$((SECONDS + STEP)) ok=no sc st ah nh
  while [ $SECONDS -lt $end ]; do ok=yes; ah=$(full_height A)
    for n in "$@"; do
      sc=$(same_chain A "$n"); st=$(same_state A "$n"); nh=$(full_height "$n")
      case "$sc" in SAME@*) ;; *) ok=no ;; esac
      case "$st" in DIFF@*|LAG@*" fork") ok=no ;; esac
      [ $((ah - ${nh:-0})) -le $LAG ] || ok=no
    done
    [ $ok = yes ] && break; sleep 3
  done
  echo "[churn] $label: converged=$ok  A=$(full_height A)  $(for n in "$@"; do printf '%s:%s@%s ' "$n" "$(same_chain A "$n" | cut -c1-7)" "$(full_height "$n")"; done)"
  [ $ok = yes ] || fail=1; }
echo "[churn] floor: B follows A"; converge "B follows" B
echo "[churn] C joins"; launch C; wait_up C; converge "C joined" B C
echo "[churn] B leaves (crash) at height $(full_height B)"; crash B; sleep 10
echo "[churn] D joins with B gone (peers B down, C up)"; launch D; wait_up D; converge "D joined without B" C D
echo "[churn] B returns"; revive B; converge "B back" B C D
# Settle window: a node whose dial is refused once drops that peer from its peer database ("Failed to connect …
# Connection refused" then "removed from peers database", PeerManager), and a returning node's P2P port can bind
# after its REST answers; so the returning node and its neighbour can each forget the other and must rediscover
# it through peer gossip (A knows everyone). That takes longer than the first retries, so the window is 200 s.
echo "[churn] settle, then peer sets vs topology (up to 200 s: a refused dial drops the peer, gossip brings it back):"; topo_ok=no
for _ in $(seq 1 20); do sleep 10; if check_topology; then topo_ok=yes; break; fi; echo "  (peer sets not yet matching the topology; retrying)"; done
[ $topo_ok = yes ] || fail=1
echo "[churn] heights: $(for n in A B C D; do printf '%s=%s ' "$n" "$(full_height "$n")"; done)"
if [ $fail = 0 ]; then rig_verdict=PASS; else rig_verdict=FAIL; fi
echo "[churn] === CHURN: $rig_verdict ==="; echo "CHURN-DONE"
