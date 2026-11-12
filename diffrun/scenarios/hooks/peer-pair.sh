# shellcheck shell=bash
# peer-pair hook (see diffrun/scenarios/peer-pair.sh): wait, then read each node's view of the other.
# Log counts come from the node's own log lines: "Failed to deserialize data from" (a message it could not parse),
# "penalized, penalty:" and "<address> blacklisted" (PeerManager). first_reason is the exception on the line after
# the first parse failure. The waits are fixed: no early exit, so both orders see the same window.
pp_wait=${PP_WAIT_S:-60}
va=$(rest A /info | jq -r '.appVersion // "null"'); vb=$(rest B /info | jq -r '.appVersion // "null"')
echo "[peer-pair] A=$va (mining), B=$vb (dials A); waiting ${pp_wait}s"
sleep "$pp_wait"
pp_node(){ local n=$1 o=$2 l c1 c2 c3 bl why con ban
  l="$RIG_LOG_DIR/node_$n.log"
  c1=$(grep -c 'Failed to deserialize data from' "$l" 2>/dev/null); c2=$(grep -c 'penalized, penalty:' "$l" 2>/dev/null)
  c3=$(grep ' blacklisted$' "$l" 2>/dev/null | grep -vc 'already blacklisted')
  why=$(grep -A1 'Failed to deserialize data from' "$l" 2>/dev/null | grep -m1 -oE '[A-Za-z.]*(Exception|Error)[^@]{0,80}' || true)
  bl=$(rest "$n" /peers/blacklisted | jq -c '.addresses // []' 2>/dev/null); [[ -n "$bl" ]] || bl='[]'
  con=false; [[ " $(peers_of "$n") " == *" $o "* ]] && con=true
  ban=false; [[ "$bl" == *"${ID_IP[$o]}"* ]] && ban=true
  echo "[peer-pair] $n: connected_to_$o=$con banned_$o=$ban parse_failures=${c1:-0} penalties=${c2:-0} blacklistings=${c3:-0} blacklisted=$bl${why:+ first_reason=\"$why\"}"
  PP_JSON+=("$(jq -cn --arg n "$n" --argjson con $con --argjson ban $ban --argjson pf "${c1:-0}" --argjson pe "${c2:-0}" --argjson bk "${c3:-0}" --arg why "$why" \
    '{($n): {connected:$con, banned_other:$ban, parse_failures:$pf, penalties:$pe, blacklistings:$bk, first_reason:$why}}')"); }
PP_JSON=(); pp_node A B; pp_node B A
nodes=$(printf '%s\n' "${PP_JSON[@]}" | jq -cs 'add')
paired=$(jq -r '.A.connected and .B.connected and (.A.banned_other|not) and (.B.banned_other|not)' <<< "$nodes")
echo "RESULT_JSON $(jq -cn --arg A "$va" --arg B "$vb" --argjson nodes "$nodes" --argjson paired "$paired" --arg jv "$(${PEERYARD_JAVA:-java} -version 2>&1 | head -1)" \
  '{schema_version:1,scenario:"peer-pair",runtime:{java:$jv},versions:{A:$A,B:$B},nodes:$nodes,metrics:{paired:$paired,banned_by_A:$nodes.A.banned_other,banned_by_B:$nodes.B.banned_other,parse_failures_A:$nodes.A.parse_failures,parse_failures_B:$nodes.B.parse_failures}}')"
rig_verdict=$([ "$paired" = true ] && echo PASS || echo FAIL)
