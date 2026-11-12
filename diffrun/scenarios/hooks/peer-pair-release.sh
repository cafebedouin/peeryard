# shellcheck shell=bash
# peer-pair-release hook (see diffrun/scenarios/peer-pair-release.sh): as hooks/peer-pair.sh, with node B a release
# jar; the payload results come in through the environment from the scenario script.
pp_wait=${PP_WAIT_S:-60}
va=$(rest A /info | jq -r '.appVersion // "null"'); vb=$(rest B /info | jq -r '.appVersion // "null"')
echo "[peer-pair-release] A=$va (this jar, mining), B=$vb (release ${PP_RELEASE_TAG:-?}, dials A); waiting ${pp_wait}s"
sleep "$pp_wait"
pp_node(){ local n=$1 o=$2 l c1 c2 c3 bl why con ban types
  l="$RIG_LOG_DIR/node_$n.log"
  c1=$(grep -c 'Failed to deserialize data from' "$l" 2>/dev/null); c2=$(grep -c 'penalized, penalty:' "$l" 2>/dev/null)
  c3=$(grep ' blacklisted$' "$l" 2>/dev/null | grep -vc 'already blacklisted')
  why=$(grep -A1 'Failed to deserialize data from' "$l" 2>/dev/null | grep -m1 -oE '[A-Za-z.]*(Exception|Error)[^@]{0,80}' || true)
  types=$(grep 'penalized, penalty:' "$l" 2>/dev/null | sed 's/.*penalty: //' | sort | uniq -c | awk '{printf "%s%s:%s", s, $2, $1; s=","}')
  bl=$(rest "$n" /peers/blacklisted | jq -c '.addresses // []' 2>/dev/null); [[ -n "$bl" ]] || bl='[]'
  con=false; [[ " $(peers_of "$n") " == *" $o "* ]] && con=true
  ban=false; [[ "$bl" == *"${ID_IP[$o]}"* ]] && ban=true
  echo "[peer-pair-release] $n: connected_to_$o=$con banned_$o=$ban parse_failures=${c1:-0} penalties=${c2:-0}${types:+ ($types)} blacklistings=${c3:-0} blacklisted=$bl${why:+ first_reason=\"$why\"}"
  PP_JSON+=("$(jq -cn --arg n "$n" --argjson con $con --argjson ban $ban --argjson pf "${c1:-0}" --argjson pe "${c2:-0}" --argjson bk "${c3:-0}" --arg why "$why" --arg ty "$types" \
    '{($n): {connected:$con, banned_other:$ban, parse_failures:$pf, penalties:$pe, penalty_types:$ty, blacklistings:$bk, first_reason:$why}}')"); }
PP_JSON=(); pp_node A B; pp_node B A
nodes=$(printf '%s\n' "${PP_JSON[@]}" | jq -cs 'add')
paired=$(jq -r '.A.connected and .B.connected and (.A.banned_other|not) and (.B.banned_other|not)' <<< "$nodes")
echo "RESULT_JSON $(jq -cn --arg A "$va" --arg B "$vb" --argjson nodes "$nodes" --argjson paired "$paired" --arg jv "$(${PEERYARD_JAVA:-java} -version 2>&1 | head -1)" \
  --arg tag "${PP_RELEASE_TAG:-}" --arg sha "${PP_RELEASE_SHA:-}" --arg v2 "${PP_V2_HEX:-}" --arg v3 "${PP_V3_HEX:-}" \
  --arg p2 "${PP_V2_PARSE:-}" --arg p3 "${PP_V3_PARSE:-}" --arg r3 "${PP_V3_REASON:-}" \
  '{schema_version:1,scenario:"peer-pair-release",runtime:{java:$jv},versions:{A:$A},release:{tag:$tag,jar_sha256:$sha,appVersion:$B},
    payload:{v2_hex:$v2,v3_hex:$v3,v2_parse:$p2,v3_parse:$p3,v3_reason:$r3},nodes:$nodes,
    metrics:{paired:$paired,banned_by_release:$nodes.B.banned_other,parse_failures_release:$nodes.B.parse_failures,
      v3_written:($v3 != "absent" and $v3 != ""),v3_parsed_by_release:($p3 == "Success"),v2_parsed_by_release:($p2 == "Success")}}')"
rig_verdict=$([ "$paired" = true ] && echo PASS || echo FAIL)
