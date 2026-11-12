# shellcheck shell=bash
# parse-error-log: what one node logs when its REST port receives input that is not HTTP. No peers, no mining.
# After REST is up the probe script (parse-error-log.py, beside this hook) sends three requests on their own
# connections, records each HTTP status and the "Illegal request" lines the node's console log gains after it,
# then /info is read to confirm the node is still answering.
# RESULT_JSON metrics, per probe pN (p1 too-long method starting with ESC, p2 short unknown method, p3 TLS-style start):
#   pN_status (HTTP status), pN_lines (warning lines logged), pN_detail (a detail follows the summary),
#   pN_nonprint (bytes outside printable ASCII in those lines); alive (/info answered after the probes);
#   pass = every probe logged a line and no line carries a detail or a non-printable byte, and alive.
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
log="$RIG_LOG_DIR/node_A.log"
res="$(ip netns exec "${NS[A]}" python3 -I "$here/parse-error-log.py" 127.0.0.1 "${REST[A]}" "$log" 2> "$SCRATCH/probe.err")"
if ! jq -e . > /dev/null 2>&1 <<< "$res"; then
  rig_verdict=INCONCLUSIVE; echo "[parse-log] probe script failed: $(head -c 300 "$SCRATCH/probe.err")"
  echo "[parse-log] === PARSE-ERROR-LOG: INCONCLUSIVE ==="; return 0
fi
for p in p1 p2 p3; do
  echo "[parse-log] $p: $(jq -c --arg p "$p" '.[$p] | {status, lines, detail, nonprint, esc}' <<< "$res")"
  jq -r --arg p "$p" '.[$p].text[] | "  " + .' <<< "$res"
done
va="$(rest A /info | jq -r '.appVersion // empty')"
alive=false; [[ -n "$va" ]] && alive=true
pass="$(jq --argjson alive "$alive" '[.p1, .p2, .p3] | all(.lines > 0 and (.detail | not) and .nonprint == 0) and $alive' <<< "$res")"
rig_verdict=$([[ $pass == true ]] && echo PASS || echo FAIL)
echo "RESULT_JSON $(jq -cn --argjson r "$res" --arg v "${va:-null}" --argjson alive "$alive" --argjson pass "$pass" \
  --arg jv "$(${PEERYARD_JAVA:-java} -version 2>&1 | head -1)" \
  '{schema_version:1, scenario:"parse-error-log", runtime:{java:$jv}, versions:{A:$v},
    metrics: ({alive:$alive, pass:$pass} + ([("p1","p2","p3") as $p | {($p+"_status"): $r[$p].status, ($p+"_lines"): $r[$p].lines,
      ($p+"_detail"): $r[$p].detail, ($p+"_nonprint"): $r[$p].nonprint}] | add))}')"
echo "[parse-log] === PARSE-ERROR-LOG: $rig_verdict ==="
