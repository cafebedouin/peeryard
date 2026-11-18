# shellcheck shell=bash
# peer-pair-keepup hook (see diffrun/scenarios/peer-pair-keepup.sh): sample both nodes' heights at fixed times (no
# early exit, so both roles see the same window), then B's view of A as in hooks/peer-pair.sh.
pk_wait=${PK_WAIT_S:-120}; pk_lag=${PK_MAX_LAG:-5}; pk_step=${PK_SAMPLE_S:-15}
va=$(rest A /info | jq -r '.appVersion // "null"'); vb=$(rest B /info | jq -r '.appVersion // "null"')
echo "[peer-pair-keepup] A=$va (mining), B=$vb (dials A); ${pk_wait}s, a sample every ${pk_step}s"
pk_h(){ rest "$1" /info | jq -c '{h: (.headersHeight // 0), f: (.fullHeight // 0)}' 2>/dev/null || echo '{"h":0,"f":0}'; }
PK_SERIES=(); t=0
while (( t < pk_wait )); do
  s=$(( pk_wait - t < pk_step ? pk_wait - t : pk_step )); sleep "$s"; t=$(( t + s ))
  a=$(pk_h A); b=$(pk_h B); [[ -n "$a" ]] || a='{"h":0,"f":0}'; [[ -n "$b" ]] || b='{"h":0,"f":0}'
  echo "[peer-pair-keepup] t=${t}s A headers=$(jq -r .h <<< "$a") full=$(jq -r .f <<< "$a")  B headers=$(jq -r .h <<< "$b") full=$(jq -r .f <<< "$b")"
  PK_SERIES+=("$(jq -cn --argjson t "$t" --argjson a "$a" --argjson b "$b" '{t:$t, a_headers:$a.h, a_full:$a.f, b_headers:$b.h, b_full:$b.f}')")
done
series=$(printf '%s\n' "${PK_SERIES[@]}" | jq -cs '.')
pk_node(){ local n=$1 o=$2 l c1 c2 c3 bl con ban
  l="$RIG_LOG_DIR/node_$n.log"
  c1=$(grep -c 'Failed to deserialize data from' "$l" 2>/dev/null); c2=$(grep -c 'penalized, penalty:' "$l" 2>/dev/null)
  c3=$(grep ' blacklisted$' "$l" 2>/dev/null | grep -vc 'already blacklisted')
  bl=$(rest "$n" /peers/blacklisted | jq -c '.addresses // []' 2>/dev/null); [[ -n "$bl" ]] || bl='[]'
  con=false; [[ " $(peers_of "$n") " == *" $o "* ]] && con=true
  ban=false; [[ "$bl" == *"${ID_IP[$o]}"* ]] && ban=true
  echo "[peer-pair-keepup] $n: connected_to_$o=$con banned_$o=$ban parse_failures=${c1:-0} penalties=${c2:-0} blacklistings=${c3:-0}"
  PK_JSON+=("$(jq -cn --arg n "$n" --argjson con $con --argjson ban $ban --argjson pf "${c1:-0}" --argjson pe "${c2:-0}" --argjson bk "${c3:-0}" \
    '{($n): {connected:$con, banned_other:$ban, parse_failures:$pf, penalties:$pe, blacklistings:$bk}}')"); }
PK_JSON=(); pk_node A B; pk_node B A
nodes=$(printf '%s\n' "${PK_JSON[@]}" | jq -cs 'add')
echo "RESULT_JSON $(jq -cn --arg A "$va" --arg B "$vb" --argjson nodes "$nodes" --argjson series "$series" --argjson lag "$pk_lag" --arg jv "$(${PEERYARD_JAVA:-java} -version 2>&1 | head -1)" \
  '($series | last) as $e | ($e.a_full - $e.b_full) as $d
   | ($nodes.A.connected and $nodes.B.connected and ($nodes.A.banned_other|not) and ($nodes.B.banned_other|not)) as $paired
   | {schema_version:1,scenario:"peer-pair-keepup",runtime:{java:$jv},versions:{A:$A,B:$B},nodes:$nodes,series:$series,
      metrics:{kept_up:($e.a_full > 0 and $d <= $lag),paired:$paired,a_full_height:$e.a_full,b_headers_height:$e.b_headers,b_full_height:$e.b_full,b_full_lag:$d}}')"
rig_verdict=$(jq -e '.[-1] | .a_full > 0 and (.a_full - .b_full) <= '"$pk_lag" <<< "$series" >/dev/null && echo PASS || echo FAIL)
