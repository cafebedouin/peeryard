# magic isolation: the rig's private network magic ("peer", [112,101,101,114]) must keep its nodes off any
# other network. A runs on the rig's magic; B is configured with the devnet default [2,2,4,4] (a per-node
# "conf" override). Both know the other as a peer. The first dial is rejected by both ends just after the
# handshake, and each end then drops the other from its peers database, so the node that did not dial never
# dials. Phase 2 therefore restarts that node: its peers database is empty, it re-seeds from its config and
# dials. PASS = each node made an outgoing connection to the other (read from its log), both ends aborted
# every such connection, neither lists a connected peer at the end, and the two mined different chains.
echo "[magic] A magic: $(grep -h magicBytes "$SCRATCH"/conf_A.conf | tail -1)"
echo "[magic] B magic: $(grep -h magicBytes "$SCRATCH"/conf_B.conf | tail -1)"
declare -A OTHER=([A]=B [B]=A)
# outgoing <node>: count of the node's outgoing connections to the other node's address (from its log)
outgoing(){ grep -c "New outgoing connection to /${ID_IP[${OTHER[$1]}]}:" "$RIG_LOG_DIR/node_$1.log"; }
# aborted <node>: count of connections with the other node the node aborted itself
aborted(){ grep "Enforced to abort communication with" "$RIG_LOG_DIR/node_$1.log" | grep -c "remote=/${ID_IP[${OTHER[$1]}]}:"; }
connected(){ rest "$1" /peers/connected | jq -r 'length' 2>/dev/null; }
watch_window(){ local end=$((SECONDS + $1))
  while [ $SECONDS -lt $end ]; do
    echo "  A.h=$(full_height A) A.connected=$(connected A) out=$(outgoing A)   B.h=$(full_height B) B.connected=$(connected B) out=$(outgoing B)"
    sleep 10
  done; }

watch_window 40
oa=$(outgoing A); ob=$(outgoing B)
echo "[magic] phase 1: outgoing A->B=$oa B->A=$ob, aborted by A=$(aborted A) by B=$(aborted B)"
second=""
if [ "$oa" -gt 0 ] && [ "$ob" -eq 0 ]; then second=B; elif [ "$ob" -gt 0 ] && [ "$oa" -eq 0 ]; then second=A; fi
if [ -n "$second" ]; then
  echo "[magic] phase 2: $second did not dial; restart it so it re-seeds its peers from its config and dials"
  crash "$second"; revive "$second"
  watch_window 40
fi

oa=$(outgoing A); ob=$(outgoing B); xa=$(aborted A); xb=$(aborted B)
ca=$(connected A); cb=$(connected B); sc=$(same_chain A B)
echo "[magic] outgoing A->B=$oa B->A=$ob; aborted by A=$xa by B=$xb; connected A=${ca:-?} B=${cb:-?}; same_chain=${sc%%:*}"
echo "[magic] log lines about the rejected peer (A's log, then B's):"
grep -i -E 'outgoing connection to|abort communication|removed from peers' "$RIG_LOG_DIR/node_A.log" | tail -4 | sed 's/^/  A: /'
grep -i -E 'outgoing connection to|abort communication|removed from peers' "$RIG_LOG_DIR/node_B.log" | tail -4 | sed 's/^/  B: /'
dials=$((oa + ob)); res=FAIL; why=""
[ "$oa" -ge 1 ] && [ "$ob" -ge 1 ] || why="$why NOT_BOTH_DIALED"
[ "$xa" -ge "$dials" ] && [ "$xb" -ge "$dials" ] || why="$why NOT_ALL_ABORTED"
[ "${ca:-1}" = 0 ] && [ "${cb:-1}" = 0 ] || why="$why CONNECTED"
[ "${sc%%@*}" = DIFF ] || why="$why CHAINS_${sc%%@*}"
[ -z "$why" ] && res=PASS
echo "[magic] === MAGIC-ISOLATION: $res (dials A->B=$oa B->A=$ob, aborts A=$xa B=$xb, connected A=${ca:-?} B=${cb:-?}, chains ${sc%%@*})${why:+ —$why} ==="
rig_verdict=$res
echo "MAGIC-DONE"
