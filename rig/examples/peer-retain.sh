# peer-retain: a node whose dial to a peer failed while that peer was restarting: does it keep the peer in its peer
# database, dial it again once it is back, and does the peer catch up? Asked of one jar per run; a pair of runs on two
# jars (a base and a change to the dial-failure rule) is the comparison.
# Topology A - B - C, A never linked to C. C mines (mine_poll 2s), so B always has another peer that is talking; A
# follows through B. Peer exchange is off on every node (scorex.network.peerDiscovery = false: no PeerSynchronizer, so
# no GetPeers or Peers message is sent or handled), so no node learns an address from another. B learns A only from
# A's handshake at bring-up (A dials B; B's knownPeers name only C), and C never learns A.
#   1. floor: A and B on C's chain at height RETAIN_FLOOR or more; A listed in B's peer database (/peers/all) and
#      connected to B; C does not list A.
#   2. A is stopped (crash: SIGKILL). B's own dial loop (every 5 s, a random known peer it is not connected to) dials A;
#      the hook waits for B's log line `Failed to connect to /<A>` (NetworkController, on CommandFailed(Connect)).
#      T0 = the time of the first such line.
#   3. A stays down RETAIN_DOWN_EXTRA_S more, then is restarted with its peer database deleted and knownPeers = [], so
#      it has no address to dial: A is passive toward B. The hook makes no /peers/connect call (nor does the rig: its
#      re-dials run only at bring-up and in relink, which this hook does not call).
#   4. The window runs to T0 + RETAIN_WINDOW_S (300), predeclared and below the node's inactiveConnectionDeadline
#      (RETAIN_DEADLINE_S, 600: the node's default; neither the rig nor this topology sets it), measured from B's first
#      failed dial. Every 2 s (peer-retain.tsv beside the node logs): A in B's /peers/all, A in B's /peers/connected
#      and in which direction, A in C's /peers/all, B-C connected, heights, same_chain A C.
# Outcomes, judged on what happened inside the window:
#   RETAINED  A listed by B at every sample, no removal line, B dialled A after the restart (B's log `New outgoing
#             connection to /<A>`, B's /peers/connected lists A as Outgoing), and A on C's chain within RETAIN_LAG blocks
#             of C at the end -> PASS
#   REMOVED   B logged `/<A> removed from peers database`, A absent from B's database from then to the end, no
#             connection from B to A after the restart -> FAIL
#   OTHER     anything else (e.g. kept but not re-dialled, re-dialled but not caught up) -> FAIL
# INCONCLUSIVE, each its own check line, when the run cannot tell: A not a known peer of B before the stop; no failed
# dial by B while A was down; inbound contact from A after its restart (A's log `Connecting to peer` or `New outgoing
# connection`, or B's log `New incoming connection from /<A's ip>`); rediscovery (C ever lists A, or B or C logs `New
# discovered peer` for A, or A listed at B again after a removal); B-C not connected in the window or C not advancing;
# A not answering by 60 s before the window ends; the window not ending before the deadline.
# Which dial-failure rule the jar carries is read from the jar (the string `kept in peers database` in
# scorex/core/network/NetworkController*.class): `deadline` or `immediate`. A pair of runs whose jars do not differ in
# it is not a comparison of that rule.
#   PEERYARD_JAR=<jar> bash rig/rig.sh rig/examples/peer-retain.json rig/examples/peer-retain.sh
# Detector: before the stop, the inbound-contact patterns must match A's own bring-up dial to B (A's `Connecting to
# peer`, B's `New incoming connection from /<A's ip>`), or the run is INCONCLUSIVE (detector-self-test).
# Control: RETAIN_CONTROL=active-a restarts A with its peer database and knownPeers kept, so A dials B itself: the
# inbound-contact check must fire (INCONCLUSIVE). Run it on a jar that removes the peer: on a jar that keeps it, B's own
# dial can reach A before A's first dial tick (5 s after start), and A, already connected, then dials nothing.
#   RETAIN_WINDOW_S (300), RETAIN_DEADLINE_S (600), RETAIN_DOWN_EXTRA_S (12), RETAIN_DIAL_WAIT_S (60), RETAIN_FLOOR (10),
#   RETAIN_LAG (4), RETAIN_CONTROL (none | active-a)
W=${RETAIN_WINDOW_S:-300}; DL=${RETAIN_DEADLINE_S:-600}; DOWNX=${RETAIN_DOWN_EXTRA_S:-12}; DIALW=${RETAIN_DIAL_WAIT_S:-60}
FLOOR=${RETAIN_FLOOR:-10}; LAG=${RETAIN_LAG:-4}; CTL=${RETAIN_CONTROL:-none}
note(){ echo "[peer-retain] $*"; }
retain_end(){ echo "[peer-retain] === PEER-RETAIN: $1 ($2) ==="; rig_verdict=$1; }
A_ADDR="${IP[A]}:${P2P[A]}"; A_IPRE="${IP[A]//./\\.}"; B_IPRE="${IP[B]//./\\.}"
TSV="$RIG_LOG_DIR/peer-retain.tsv"; STOPF="$SCRATCH/peer-retain.stop"
# log_ms <HH:MM:SS.mmm>: a node log time (local time, no date) as epoch milliseconds, today (yesterday if that is ahead)
log_ms(){ local ms now; now=$(date +%s%3N); ms=$(date -d "$(date +%F) $1" +%s%3N 2>/dev/null) || return 1
  (( ms > now + 60000 )) && ms=$((ms - 86400000)); echo "$ms"; }
first_ms(){ local l; l=$(grep -m1 -E "$1" <<< "$2"); [[ -n "$l" ]] && log_ms "${l:0:12}"; }
rel(){ [[ -n "$1" && -n "$T0" ]] && awk -v a="$1" -v b="$T0" 'BEGIN { printf "%+.1f", (a - b) / 1000 }' || echo "-"; }
lines_after(){ sed -n "$(( $2 + 1 )),\$p" "$RIG_LOG_DIR/node_$1.log"; }
# one sampler row: t ball bconn call aconn aup ah bh ch bc sc
retain_row(){ local t ball bconn call aconn aup=0 ah=0 bh ch bc sc="-" pa pc
  t=$(date +%s%3N)
  pa=$(rest B /peers/all); ball=$(jq -r --arg a "$A_ADDR" '[.[]? | select((.address // "" | ltrimstr("/")) == $a)] | length' <<< "$pa" 2>/dev/null)
  pc=$(rest B /peers/connected)
  bconn=$(jq -r '[.[]? | select(.name == "A") | (.connectionType // "?")] | first // "-"' <<< "$pc" 2>/dev/null)
  bc=$(jq -r '[.[]? | select(.name == "C")] | length' <<< "$pc" 2>/dev/null)
  call=$(rest C /peers/all | jq -r --arg a "$A_ADDR" '[.[]? | select((.address // "" | ltrimstr("/")) == $a)] | length' 2>/dev/null)
  aconn=$(rest A /peers/connected | jq -r '[.[]? | select(.name == "B") | (.connectionType // "?")] | first // "-"' 2>/dev/null)
  ah=$(rest A /info | jq -r '.fullHeight // empty' 2>/dev/null); [[ -n "$ah" ]] && aup=1 || ah=0
  bh=$(full_height B); ch=$(full_height C)
  [[ $aup == 1 ]] && sc=$(same_chain A C | cut -d@ -f1)
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$t" "${ball:-?}" "${bconn:-?}" "${call:-?}" "${aconn:-?}" "$aup" "$ah" "${bh:-?}" "${ch:-?}" "${bc:-?}" "$sc"; }

peer_retain(){
  local jarB rule h ah bh ch sc ball bconn call ok i boff aoff boff2 t_stop t_rev t_up t_end T0="" blog blog2 alog clog fails
  local rm_l rm_ms kept_n kept_last bout_ms ain_ms b_in a_dials a_out b_disc c_disc a_seed bstat age chk incs="" outcome
  local retained=false removed=false redial=false converged=false relisted=0 c_max bc_lost c0 c1 last v n aup ball_bad ball_n
  case "$CTL" in none|active-a) ;; *) retain_end INCONCLUSIVE "RETAIN_CONTROL '$CTL': none or active-a"; return ;; esac
  [[ $W -lt $DL ]] || { retain_end INCONCLUSIVE "RETAIN_WINDOW_S $W is not below RETAIN_DEADLINE_S $DL"; return; }
  jarB="${NODE_JAR[B]}"
  # grep -c reads the whole stream: with pipefail, grep -q would end the pipe early and unzip's SIGPIPE would read as no match
  rule=immediate; [[ "$(unzip -p "$jarB" 'scorex/core/network/NetworkController*' 2>/dev/null | grep -a -c 'kept in peers database')" -gt 0 ]] && rule=deadline
  for n in A B C; do v=$(rest "$n" /info | jq -r '.appVersion // "null"'); note "$n appVersion $v jar $(basename "${NODE_JAR[$n]}") sha256 $(sha256sum "${NODE_JAR[$n]}" | cut -d' ' -f1)"; done
  note "dial-failure rule in B's jar: $rule (deadline = the string 'kept in peers database' is in NetworkController; immediate = it is not)"
  note "A's identity address $A_ADDR; window ${W}s from B's first failed dial; deadline ${DL}s; control: $CTL"

  # 1. floor
  check_topology_wait 90 | sed 's/^/  /'
  ok=no; local end=$((SECONDS + 180))
  while [[ $SECONDS -lt $end ]]; do ah=$(full_height A); ch=$(full_height C); sc=$(same_chain A C)
    [[ "$sc" == SAME@* && "${ah:-0}" -ge $FLOOR && $(( ${ch:-0} - ${ah:-0} )) -le $LAG ]] && { ok=yes; break; }; sleep 3; done
  note "floor: A=$(full_height A) B=$(full_height B) C=$(full_height C) same_chain(A,C)=${sc:0:20} reached=$ok"
  [[ $ok == yes ]] || { retain_end INCONCLUSIVE "A did not reach C's chain at height $FLOOR or more"; return; }
  : > "$TSV"; rm -f "$STOPF"
  ( while [[ ! -f "$STOPF" ]]; do retain_row >> "$TSV"; sleep 2; done ) & local SAMPLER=$!; BG_PIDS+=("$SAMPLER")
  sleep 4
  read -r _ ball bconn call _ < <(tail -1 "$TSV")
  bstat=$(rest B /peers/status); age=$(jq -r '(.currentSystemTime // 0) - (.lastIncomingMessage // 0)' <<< "$bstat" 2>/dev/null)
  note "before the stop: A in B's database=$ball, A connected to B=$bconn, A in C's database=$call, B's last incoming message ${age:-?} ms ago"
  if [[ "$ball" != 1 ]]; then touch "$STOPF"; note "check known-peer: MISSING (A not in B's /peers/all before the stop)"; retain_end INCONCLUSIVE "A was not a known peer of B"; return; fi
  note "check known-peer: OK"

  # detector self-test: the inbound-contact patterns must match A's own bring-up dial to B in the same logs (A's
  # knownPeers name B, and the bring-up re-dial, when needed, also goes from A), or a NONE below would mean nothing
  local a_pre b_pre
  a_pre=$(grep -c -F "Connecting to peer" "$RIG_LOG_DIR/node_A.log"); b_pre=$(grep -c -E "New incoming connection from /${A_IPRE}:" "$RIG_LOG_DIR/node_B.log")
  if [[ $a_pre -lt 1 || $b_pre -lt 1 ]]; then touch "$STOPF"; note "check detector-self-test: BLIND (before the stop: A dial lines $a_pre, B incoming-from-A lines $b_pre)"
    retain_end INCONCLUSIVE "the inbound-contact patterns match nothing in A's bring-up"; return; fi
  note "check detector-self-test: OK (before the stop: A dial lines $a_pre, B incoming-from-A lines $b_pre)"

  # 2. stop A; wait for B's failed dial
  boff=$(wc -l < "$RIG_LOG_DIR/node_B.log"); t_stop=$(date +%s%3N); mark "peer-retain: stop A"; crash A
  end=$((SECONDS + DIALW))
  while [[ $SECONDS -lt $end ]]; do lines_after B "$boff" | grep -q -F "Failed to connect to /$A_ADDR" && break; sleep 1; done
  T0=$(first_ms "Failed to connect to /${A_ADDR//./\\.}" "$(lines_after B "$boff")")
  if [[ -z "$T0" ]]; then touch "$STOPF"; note "check failed-dial: MISSING (no 'Failed to connect to /$A_ADDR' in B's log within ${DIALW}s of the stop)"
    retain_end INCONCLUSIVE "B made no failed dial to A while A was down"; return; fi
  mark "peer-retain: B's first failed dial to A"
  note "B's first failed dial to A at T0 = $(date -d "@${T0:0:10}" -Iseconds) (+$(awk -v a="$T0" -v b="$t_stop" 'BEGIN { printf "%.1f", (a - b) / 1000 }') s after the stop)"
  sleep "$DOWNX"

  # 3. restart A, passive toward B (no stored peers, no configured peers), unless the control keeps them
  if [[ "$CTL" == active-a ]]; then note "control active-a: A restarts with its peer database and knownPeers kept (it will dial B)"
  else rm -rf "$SCRATCH/data_A/peers"; CONF_OVR[A]="scorex.network.knownPeers=[]"; fi
  aoff=$(wc -l < "$RIG_LOG_DIR/node_A.log"); boff2=$(wc -l < "$RIG_LOG_DIR/node_B.log"); t_rev=$(date +%s%3N)
  revive A; t_up=$(date +%s%3N)
  note "A restarted at $(rel "$t_rev") s, REST up at $(rel "$t_up") s (from T0); observing to +${W}s; no /peers/connect from here"

  # 4. the window
  while [[ $(date +%s%3N) -lt $(( T0 + W * 1000 )) ]]; do sleep 1; done
  t_end=$(date +%s%3N); touch "$STOPF"; sleep 3; kill "$SAMPLER" 2>/dev/null; wait "$SAMPLER" 2>/dev/null
  blog=$(lines_after B "$boff"); blog2=$(lines_after B "$boff2"); alog=$(lines_after A "$aoff"); clog=$(cat "$RIG_LOG_DIR/node_C.log")
  fails=$(grep -c -F "Failed to connect to /$A_ADDR" <<< "$blog")
  rm_l=$(grep -m1 -F "/$A_ADDR removed from peers database" <<< "$blog"); rm_ms=""; [[ -n "$rm_l" ]] && rm_ms=$(log_ms "${rm_l:0:12}")
  kept_n=$(grep -c -F "/$A_ADDR kept in peers database" <<< "$blog"); kept_last=$(grep -F "/$A_ADDR kept in peers database" <<< "$blog" | tail -1 | sed 's/.* - //')
  bout_ms=$(first_ms "New outgoing connection to /${A_ADDR//./\\.}" "$blog2")
  ain_ms=$(first_ms "New incoming connection from /${B_IPRE}:" "$alog")
  b_in=$(grep -c -E "New incoming connection from /${A_IPRE}:" <<< "$blog2")
  a_dials=$(grep -c -F "Connecting to peer" <<< "$alog"); a_out=$(grep -c -F "New outgoing connection to" <<< "$alog")
  b_disc=$(grep -c -E "New discovered peer.*${A_IPRE}" <<< "$blog"); c_disc=$(grep -c -E "New discovered peer.*${A_IPRE}" <<< "$clog")
  a_seed=$(grep -m1 -E "No peers in database|peers read from the database" <<< "$alog" | sed 's/.* - //')

  # the samples inside the window [T0, t_end]
  awk -F'\t' -v a="$T0" -v b="$t_end" '$1 >= a && $1 <= b' "$TSV" > "$TSV.window"
  ball_bad=$(awk -F'\t' '$2 == "0"' "$TSV.window" | wc -l); ball_n=$(awk -F'\t' '$2 ~ /^[0-9]+$/' "$TSV.window" | wc -l)
  [[ -n "$rm_ms" ]] && relisted=$(awk -F'\t' -v r="$rm_ms" '$1 > r + 3000 && $2 != "0" && $2 ~ /^[0-9]+$/' "$TSV.window" | wc -l)
  c_max=$(awk -F'\t' 'BEGIN { m = 0 } $4 ~ /^[0-9]+$/ && $4 > m { m = $4 } END { print m }' "$TSV")
  bc_lost=$(awk -F'\t' '$10 == "0"' "$TSV.window" | wc -l)
  c0=$(awk -F'\t' '$9 ~ /^[0-9]+$/ { print $9; exit }' "$TSV.window"); c1=$(awk -F'\t' '$9 ~ /^[0-9]+$/ { v = $9 } END { print v }' "$TSV.window")
  last=$(awk -F'\t' '$1 <= '"$t_end"'' "$TSV" | tail -1)
  IFS=$'\t' read -r _ _ bconn _ _ aup ah bh ch _ sc <<< "$last"
  local redial_s; redial_s=$(awk -F'\t' -v r="$t_rev" '$1 >= r && $3 == "Outgoing" { print $1; exit }' "$TSV.window")

  note "peer-state transitions (t from T0; ball = A in B's /peers/all, bconn = A in B's /peers/connected, call = A in C's /peers/all, aconn = B in A's /peers/connected, bc = C connected to B):"
  awk -F'\t' -v t0="$T0" 'BEGIN { print "  t_s\tball\tbconn\tcall\taconn\ta_up\tA_h\tB_h\tC_h\tbc\tsame_chain(A,C)" }
    { k = $2 FS $3 FS $4 FS $5 FS $6 FS $10; if (k != p) { printf "  %+.1f\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", ($1 - t0) / 1000, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11; p = k } last = $0 }
    END { split(last, f, FS); printf "  %+.1f\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s  (last)\n", (f[1] - t0) / 1000, f[2], f[3], f[4], f[5], f[6], f[7], f[8], f[9], f[10], f[11] }' "$TSV"
  note "B's log after the stop: failed dials to A $fails; removal line at $(rel "$rm_ms") s${rm_l:+ ('$(sed 's/.* - //' <<< "$rm_l")')}; kept lines $kept_n${kept_last:+ (last: '$kept_last')}"
  note "after A's restart: B's outgoing connection to A at $(rel "$bout_ms") s; A's incoming connection from B at $(rel "$ain_ms") s; first sample with A Outgoing at B: $(rel "$redial_s") s"
  note "A's own dialling after the restart: 'Connecting to peer' $a_dials, outgoing connections $a_out; A's peer database at start: ${a_seed:-?}"
  note "end of window ($(rel "$t_end") s): A=$ah B=$bh C=$ch same_chain(A,C)=$sc, A at B: $bconn"

  # checks that make the run unable to tell
  note "check failed-dial: OK ($fails failed dials by B to A after the stop; the first at T0, while A was down: restart at $(rel "$t_rev") s)"
  if [[ $a_dials -gt 0 || $a_out -gt 0 || $b_in -gt 0 ]]; then note "check inbound-contact: SEEN (A dial lines $a_dials, A outgoing $a_out, B incoming from A $b_in)"; incs+=" inbound-contact"
  else note "check inbound-contact: NONE"; fi
  if [[ ${c_max:-0} -gt 0 || $b_disc -gt 0 || $c_disc -gt 0 || $relisted -gt 0 ]]; then note "check rediscovery: SEEN (C listed A: $c_max; discovered-peer lines B $b_disc, C $c_disc; A listed at B after the removal: $relisted samples)"; incs+=" rediscovery"
  else note "check rediscovery: NONE (C never listed A; no discovered-peer line for A)"; fi
  if [[ $bc_lost -gt 0 || -z "$c0" || -z "$c1" || $c1 -le $c0 ]]; then note "check other-peer-active: LOST (samples with C not connected to B: $bc_lost; C height $c0 -> $c1)"; incs+=" other-peer"
  else note "check other-peer-active: OK (C connected to B in every sample, C height $c0 -> $c1)"; fi
  if [[ $t_up -gt $(( T0 + W * 1000 - 60000 )) ]]; then note "check a-up: LATE (REST up at $(rel "$t_up") s)"; incs+=" a-late"; else note "check a-up: OK"; fi
  if [[ $t_end -ge $(( T0 + DL * 1000 )) ]]; then note "check window: OVER (ended at $(rel "$t_end") s, deadline +${DL} s)"; incs+=" window"
  else note "check window: OK (ended at $(rel "$t_end") s, before the deadline at +${DL} s from T0)"; fi

  # outcome
  [[ $ball_n -gt 0 && $ball_bad -eq 0 && -z "$rm_l" ]] && retained=true
  [[ -n "$bout_ms" && -n "$redial_s" ]] && redial=true
  [[ "$sc" == SAME && "$ah" =~ ^[0-9]+$ && "$ch" =~ ^[0-9]+$ && $(( ch - ah )) -le $LAG ]] && converged=true
  [[ -n "$rm_l" && $relisted -eq 0 && $redial == false && -z "$bout_ms" && "$bconn" == "-" ]] && removed=true
  if [[ $retained == true && $redial == true && $converged == true ]]; then outcome=RETAINED
  elif [[ $removed == true ]]; then outcome=REMOVED
  else outcome="OTHER(retained=$retained redialled=$redial converged=$converged removal-line=$([[ -n "$rm_l" ]] && echo yes || echo no))"; fi
  note "outcome: $outcome (rule in jar: $rule)"
  jq -n --arg rule "$rule" --arg jar "$(basename "$jarB")" --arg sha "$(sha256sum "$jarB" | cut -d' ' -f1)" --arg ctl "$CTL" \
    --argjson t0 "$T0" --argjson ts "$t_stop" --argjson tr "$t_rev" --argjson tu "$t_up" --argjson te "$t_end" \
    --arg rm "${rm_ms:-}" --arg bo "${bout_ms:-}" --arg ai "${ain_ms:-}" --argjson fails "$fails" --argjson kept "$kept_n" \
    --argjson adials "$a_dials" --argjson aout "$a_out" --argjson bin "$b_in" --argjson cmax "${c_max:-0}" --argjson bdisc "$b_disc" \
    --argjson cdisc "$c_disc" --argjson rel "$relisted" --argjson bclost "$bc_lost" --arg ah "$ah" --arg bh "$bh" --arg ch "$ch" --arg sc "$sc" \
    --arg outcome "$outcome" --arg incs "${incs# }" --argjson w "$W" --argjson dl "$DL" \
    '{rule: $rule, jar: $jar, sha256: $sha, control: $ctl, window_s: $w, deadline_s: $dl, t0: $t0, t_stop: $ts, t_restart: $tr, t_up: $tu, t_end: $te,
      t_removal: ($rm | if . == "" then null else tonumber end), t_b_outgoing: ($bo | if . == "" then null else tonumber end),
      t_a_incoming: ($ai | if . == "" then null else tonumber end), failed_dials: $fails, kept_lines: $kept, a_dial_lines: $adials,
      a_outgoing: $aout, b_incoming_from_a: $bin, c_listed_a: $cmax, b_discovered_a: $bdisc, c_discovered_a: $cdisc, relisted_samples: $rel,
      bc_lost_samples: $bclost, end: {A: $ah, B: $bh, C: $ch, same_chain_ac: $sc}, outcome: $outcome, inconclusive: $incs}' > "$RIG_LOG_DIR/peer-retain.json"
  if [[ -n "$incs" ]]; then retain_end INCONCLUSIVE "${incs# }; outcome would read $outcome"; return; fi
  if [[ -n "${DIFFRUN_ROLE:-}" ]]; then
    echo "RESULT_JSON $(jq -cn --arg va "$(rest A /info | jq -r '.appVersion // "null"')" --arg vb "$(rest B /info | jq -r '.appVersion // "null"')" \
      --arg vc "$(rest C /info | jq -r '.appVersion // "null"')" --arg rule "$rule" --arg jv "$(${PEERYARD_JAVA:-java} -version 2>&1 | head -1)" \
      --argjson ret "$retained" --argjson red "$redial" --argjson conv "$converged" --argjson rem "$removed" --argjson fails "$fails" \
      --argjson pass "$([[ $outcome == RETAINED ]] && echo true || echo false)" --argjson deadline_rule "$([[ $rule == deadline ]] && echo true || echo false)" \
      '{schema_version:1,scenario:"peer-retain",runtime:{java:$jv},versions:{A:$va,B:$vb,C:$vc},metrics:{retained:$ret,redialled:$red,converged:$conv,removed:$rem,failed_dials:$fails,deadline_rule:$deadline_rule,pass:$pass}}')"
  fi
  case "$outcome" in
    RETAINED) retain_end PASS "retained: B kept A through the window, dialled it after its restart, A caught up" ;;
    REMOVED) retain_end FAIL "removed: B dropped A after a failed dial and did not dial it again" ;;
    *) retain_end FAIL "$outcome" ;;
  esac
}
peer_retain
