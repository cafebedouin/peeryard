# peer-retain-mech.sh: sourced by peer-retain.sh; an opt-in sampler, off unless PEER_RETAIN_MECH=1 (the extra REST
# calls change the scenario's timing, so the default run does not make them). When on, from the floor to the end of the
# window, every ~2 s one row into $RIG_LOG_DIR/mech-samples.jsonl: B's /info heights, B's /peers/syncInfo and
# /peers/trackInfo as returned (parsed JSON, or the raw string when it does not parse), A's /info heights, C's /info
# fullHeight. t = before the first call, t_done = after the last; calls run in the order listed.
MECH_JSONL="$RIG_LOG_DIR/mech-samples.jsonl"
mech_row(){ local t t2 bi si ti ai ci
  t=$(date +%s%3N)
  bi=$(rest B /info); si=$(rest B /peers/syncInfo); ti=$(rest B /peers/trackInfo); ci=$(rest C /info); ai=$(rest A /info)
  t2=$(date +%s%3N)
  jq -cn --argjson t "$t" --argjson t2 "$t2" --arg bi "$bi" --arg si "$si" --arg ti "$ti" --arg ci "$ci" --arg ai "$ai" '
    def j: (try fromjson catch null);
    def h: (j) as $x | if $x == null then null else {full: $x.fullHeight, headers: $x.headersHeight} end;
    {t: $t, t_done: $t2, B: ($bi | h), C: ($ci | h), A: ($ai | h),
     syncInfo: (($si | j) // (if $si == "" then null else $si end)),
     trackInfo: (($ti | j) // (if $ti == "" then null else $ti end))}'; }
mech_start(){ [[ "${PEER_RETAIN_MECH:-0}" == 1 ]] || return 0; : > "$MECH_JSONL"
  ( while [[ ! -f "$STOPF" ]]; do mech_row >> "$MECH_JSONL"; sleep 2; done ) & MECH_PID=$!; BG_PIDS+=("$MECH_PID"); }
mech_stop(){ [[ -n "${MECH_PID:-}" ]] && { kill "$MECH_PID" 2>/dev/null; wait "$MECH_PID" 2>/dev/null; }; }
