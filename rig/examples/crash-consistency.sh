# crash-consistency: a node killed with SIGKILL at arbitrary points while it applies blocks must, once restarted, end up
# exactly where an untouched peer is. M mines; R follows and is never touched (the reference); S (the subject) is made to
# apply a burst of blocks and is killed K times inside that burst, each kill followed by a restart from its own disk.
# After the last restart S settles with M, and S, R and M are compared at an equal height by best full block id and UTXO
# state root (and, with the indexer on, by their /blockchain answers); S's log is searched for unrecoverable errors.
# The outcome comes from rig/crash-verdict.sh: SAME / DIFF@h / LOGERR@h / STUCK / REFUSED / INCONCLUSIVE.
# Full description, kill-point rule, settle rule and controls: rig/CRASH-CONSISTENCY.md.
#   PEERYARD_JAR=<jar> bash rig/rig.sh rig/examples/crash-consistency.json rig/examples/crash-consistency.sh
# Env (defaults in brackets):
#   CC_SEED [from the clock]   seeds every random choice (kill count, kill points, jitter); printed, so a run's choices
#                              can be repeated (the moments still depend on timing)
#   CC_KILLS [3-5 by the seed] kills per run
#   CC_ROLE [follower]         what S is: follower (full UTXO state) | digest | pruned (blocksToKeep CC_KEEP [20]) | miner
#                              (S mines too, at CC_SUBJECT_POLL [1s]; its last restart is with mining off)
#   CC_INDEXER [0]             1: extraIndex on S and R, and their indexer answers compared at the end
#   CC_KILL [height; time for the miner role]   how a kill point is chosen: height = when S's height first reaches a
#                              random target inside the burst; time = a random delay after the burst starts
#   CC_KILL_ON [full]          the height the trigger reads: full (best full block) | indexed (the indexer's height)
#   CC_BACKLOG [60]            blocks M mines above S before each burst
#   CC_RATE_KBIT [256]         the M->S link's rate (netem), so a burst is applied over seconds rather than in one
#                              batch a poll cannot catch; 0 = unshaped
#   CC_JITTER_MS [50]          a random 0..N ms wait between the trigger and the kill (spreads the kill over the write
#                              sequence of the next few blocks instead of always just after the logged one)
#   CC_KILL_MIN_MS, CC_KILL_MAX_MS [0, 8000]    time mode: the delay range
#   CC_SYNC_WAIT_S [180]       how long a burst may take to reach the trigger (a heal can take ~50 s to resume sync)
#   CC_UP_S [180]              how long a restarted S may take to answer REST
#   CC_SETTLE_S [240], CC_FINAL_S [90]   the settle window (settle_follow) and the final sampling window
#   CC_MIN_IN_WINDOW [ceil(K/2)]  kills that must land inside the burst, or the run is INCONCLUSIVE
#   CC_FATAL_RE                an ERE of unrecoverable log lines (default below)
#   CC_CONTROL [none]          aa (the same bursts, no kill: must be SAME) | no-restart (S left down after the last kill:
#                              must be REFUSED) | behind (S cut from M before the settle: must be STUCK) | fork (S cut and
#                              mining its own blocks before the settle: must be DIFF)
# Verdict: PASS on SAME; FAIL on DIFF / LOGERR / STUCK / REFUSED (a control expects its own FAIL outcome, and says whether
# it fired); INCONCLUSIVE when the staging did not happen. Prints RESULT_JSON for diffrun (diffrun/scenarios/crash-consistency.sh)
# unless the outcome is INCONCLUSIVE, which prints an `INCONCLUSIVE:` line instead.
here_cc="$(dirname "$(readlink -f "$HOOK")")"
# shellcheck source=rig/lib/indexer.sh
source "$here_cc/../lib/indexer.sh"
CC_OUT="$RIG_LOG_DIR/crash-consistency"; mkdir -p "$CC_OUT"
ROLE=${CC_ROLE:-follower}; IDX=${CC_INDEXER:-0}; CONTROL=${CC_CONTROL:-none}
SEED=${CC_SEED:-$(( $(date +%s%N) % 2147483647 ))}; RANDOM=$SEED
K=${CC_KILLS:-$(( 3 + RANDOM % 3 ))}
KILL_MODE=${CC_KILL:-$([ "$ROLE" = miner ] && echo time || echo height)}; KILL_ON=${CC_KILL_ON:-full}
BACKLOG=${CC_BACKLOG:-60}; RATE=${CC_RATE_KBIT:-256}; JITTER_MS=${CC_JITTER_MS:-50}; KMIN=${CC_KILL_MIN_MS:-0}; KMAX=${CC_KILL_MAX_MS:-8000}
SYNC_WAIT_S=${CC_SYNC_WAIT_S:-180}; UP_S=${CC_UP_S:-180}; SETTLE_S=${CC_SETTLE_S:-240}; FINAL_S=${CC_FINAL_S:-90}
MIN_IN=${CC_MIN_IN_WINDOW:-$(( (K + 1) / 2 ))}; [ "$CONTROL" = aa ] && MIN_IN=0
FATAL_RE=${CC_FATAL_RE:-'Failed to recover state|NodeViewHolder failed|Attempted node view holder restart|Rollback failed|Stopped extra indexer|Attempted extra indexer restart|removeAfter during rollback failed|No rollback height found|Unknown (address|token|template) spent box|OutOfMemoryError|Exception in thread'}
STAGE_FAIL=()   # staging problems of this hook (the rig's own harness failures are added at the end)
cc(){ echo "[cc] $*"; }
stage_fail(){ STAGE_FAIL+=("$1"); cc "STAGING: $1"; }
case "$ROLE" in follower|digest|pruned|miner) ;; *) stage_fail "unknown CC_ROLE '$ROLE'"; ROLE=follower ;; esac
case "$CONTROL" in none|aa|no-restart|behind|fork) ;; *) stage_fail "unknown CC_CONTROL '$CONTROL'"; CONTROL=none ;; esac
case "$KILL_MODE" in height|time) ;; *) stage_fail "unknown CC_KILL '$KILL_MODE'"; KILL_MODE=height ;; esac
[ "$KILL_ON" = indexed ] && [ "$IDX" != 1 ] && { stage_fail "CC_KILL_ON=indexed needs CC_INDEXER=1"; KILL_ON=full; }
cc "seed=$SEED kills=$K role=$ROLE indexer=$IDX kill=$KILL_MODE on=$KILL_ON backlog=$BACKLOG rate=${RATE}kbit jitter<=${JITTER_MS}ms control=$CONTROL min_in_window=$MIN_IN"

# ---- S's role and the indexer, set before the deferred first launches ----
case "$ROLE" in
  digest) CONF_OVR[S]="ergo.node.stateType=digest" ;;
  pruned) CONF_OVR[S]="ergo.node.blocksToKeep=${CC_KEEP:-20}" ;;
  miner)  MINING_OVR[S]=true; POLL_OVR[S]=${CC_SUBJECT_POLL:-1s} ;;
esac
if [ "$IDX" = 1 ]; then
  CONF_OVR[S]="${CONF_OVR[S]:+${CONF_OVR[S]}$'\n'}ergo.node.extraIndex=true"; CONF_OVR[R]="ergo.node.extraIndex=true"; fi
launch R; launch S
wait_up R || stage_fail "R never answered at its first launch"; wait_up S || stage_fail "S never answered at its first launch"
check_topology_wait 90 >/dev/null || cc "note: topology not fully connected after 90 s"
VERSIONS="$(jq -cn --arg M "$(rest M /info | jq -r '.appVersion // "null"')" --arg R "$(rest R /info | jq -r '.appVersion // "null"')" \
  --arg S "$(rest S /info | jq -r '.appVersion // "null"')" '{M: $M, R: $R, S: $S}')"
cc "versions $VERSIONS; S conf: $(tr '\n' ' ' <<< "${CONF_OVR[S]:-none}")mining=${MINING_OVR[S]:-cfg}"

# ---- observation helpers ----
info_of(){ rest "$1" /info 2>/dev/null; }
indexed_of(){ rest "$1" /blockchain/indexedHeight 2>/dev/null | jq -r '.indexedHeight // -1' 2>/dev/null || echo -1; }
node_obs(){ # node_obs <name>: one /info read as the classifier's node record
  local i; i="$(info_of "$1")"
  if jq -e '.appVersion' >/dev/null 2>&1 <<< "$i"; then
    jq -c '{answered: true, full: .fullHeight, headers: .headersHeight, bestFull: .bestFullHeaderId, bestHeader: .bestHeaderId, root: .stateRoot}' <<< "$i"
  else echo '{"answered": false, "full": null, "headers": null, "bestFull": null, "bestHeader": null, "root": null}'; fi; }
now_ms(){ date +%s%3N; }

# ---- S's log as the clock of its writes ----
# A burst is applied faster than REST can be polled (seen: 66 blocks between two /info reads 0.1 s apart), so the
# kill trigger reads S's own log, which the node writes as it applies each block (v6.0.7 strings):
#   full block applied:  "... applied to UtxoState at height <h>"   (UTXO state; digest: "Got new full block <id> at height <h>")
#   indexer:             "Buffered block <h> / <chain height> ..."
#   header:              "New best header <id> with score <n>. New height <h>, old height <h>"
LOG_S="$RIG_LOG_DIR/node_S.log"
RE_FULL='applied to UtxoState at height ([0-9]+)'; [ "$ROLE" = digest ] && RE_FULL='Got new full block [0-9a-f]+ at height ([0-9]+)'
RE_IDX='Buffered block ([0-9]+) /'; RE_HDR='New best header [0-9a-f]+ with score [0-9]+\. New height ([0-9]+)'
TRIG_RE=${CC_TRIGGER_RE:-$([ "$KILL_ON" = indexed ] && echo "$RE_IDX" || echo "$RE_FULL")}
log_off(){ stat -c %s "$LOG_S" 2>/dev/null || echo 0; }
# log_heights <offset> <ERE with one group>: the heights the pattern captured in S's log after <offset>, in order
log_heights(){ tail -c +$(( $1 + 1 )) "$LOG_S" 2>/dev/null | sed -nE "s/.*$2.*/\1/p"; }
log_last(){ local h; h=$(log_heights "$1" "$2" | tail -1); echo "${h:--1}"; }
# the watcher: a background tail of S's log that prints each trigger height as the node writes it
kill_tree(){ local c; for c in $(pgrep -P "$1" 2>/dev/null); do kill_tree "$c"; done; kill "$1" 2>/dev/null; return 0; }
watch_start(){ exec {WFD}< <(exec timeout "$SYNC_WAIT_S" tail -n0 -F "$LOG_S" 2>/dev/null | sed -u -nE "s/.*${TRIG_RE}.*/\1/p"); WPID=$!; }
watch_stop(){ exec {WFD}<&-; kill_tree "$WPID"; }
# watch_until <target> <deadline epoch ms>: returns 0 with HIT set once the watcher prints a height >= target
watch_until(){ local h left; HIT=""
  while :; do left=$(( $2 - $(now_ms) )); [ $left -le 0 ] && return 1
    read -r -t "$(awk -v l="$left" 'BEGIN { printf "%.3f", l / 1000 }')" -u "$WFD" h || return 1
    [ "${h:-0}" -ge "$1" ] 2>/dev/null && { HIT=$h; return 0; }; done; }

# ---- floor: R and S on M's chain ----
end=$((SECONDS + 240))
while [ $SECONDS -lt $end ]; do
  [ "$(same_chain M R | cut -c1-4)" = SAME ] && [ "$(same_chain M S | cut -c1-4)" = SAME ] && [ "$(full_height S)" -ge 5 ] && [ "$(full_height R)" -ge 5 ] && break
  sleep 3; done
[ "$(same_chain M S | cut -c1-4)" = SAME ] || stage_fail "floor: S never joined M's chain ($(same_chain M S | cut -c1-40))"
cc "floor: M=$(full_height M) R=$(full_height R) S=$(full_height S)"

# shape_s: the M->S rate, at the start and after every heal (heal restores the topology's unshaped link)
shape_s(){ [ "$RATE" -gt 0 ] 2>/dev/null && link_netem M S "rate ${RATE}kbit"; return 0; }
shape_s
# wait_backlog <base>: until M is BACKLOG blocks above <base> (at most 300 s)
wait_backlog(){ local e=$((SECONDS + 300)); while [ $SECONDS -lt $e ] && [ "$(full_height M)" -lt $(( $1 + BACKLOG )) ]; do sleep 2; done; }
# wait_loaded: a restarted node answers REST before it has read its chain (fullHeight 0 or absent); up to 90 s
wait_loaded(){ local e=$((SECONDS + 90)); while [ $SECONDS -lt $e ]; do [ "$(full_height S 2>/dev/null)" -ge 1 ] 2>/dev/null && return 0; sleep 0.25; done; return 1; }

KILLS_JSONL="$CC_OUT/kills.jsonl"; : > "$KILLS_JSONL"; done_k=0; in_k=0; came_back_all=yes; KILL_PF=0; KILL_IDX=-1
# restart <k>: bring S back from its own disk (revive: launch, then REST within CC_UP_S) and report how it came back;
# sets RESTART_OK. The height S restored is read from its log afterwards (the first block it applies, minus one).
restart(){ local k=$1 t0 up ok
  RS_OFF=$(log_off); t0=$(now_ms); if PEERYARD_UP_TIMEOUT=$UP_S revive S; then ok=true; else ok=false; came_back_all=no; fi
  up=$(( $(now_ms) - t0 )); RESTART_OK=$ok; RS_K=$k; RS_UP=$up; RS_PF=$KILL_PF
  cc "restart after kill $k: came_back=$ok rest_after=${up}ms"; }
# restart_report: once the burst after a restart is over, the restart's record (restored height from the log)
restart_report(){ local f1
  f1=$(log_heights "$RS_OFF" "$RE_FULL" | head -1); [ -n "$f1" ] && f1=$(( f1 - 1 )) || f1=-1
  cc "restart after kill $RS_K: restored full height $f1 (first block applied after the restart, minus one; last applied before the kill: $RS_PF)"
  jq -cn --argjson k "$RS_K" --argjson ok "$RESTART_OK" --argjson up "$RS_UP" --argjson h "$f1" --argjson pf "$RS_PF" \
    '{restart_after_kill: $k, came_back: $ok, rest_ms: $up, restored_full: $h, full_at_kill: $pf}' >> "$KILLS_JSONL"; }
# burst <k> <lo> <hi> <start command...>: run the start command (a heal, or a restart) and kill S at the kill point
# inside the burst that follows (or, under the A/A control, only record the point). lo = S's height before the
# burst, hi = M's. Every draw is made for every kill, whatever the mode, so a seed fixes the same choices in either.
burst(){ local k=$1 lo=$2 hi=$3 frac jit delay span target trig="" t0 tk off sl sh si mh inw dl; shift 3
  frac=$((RANDOM % 1000)); jit=$((RANDOM % (JITTER_MS + 1))); delay=$(( KMIN + (RANDOM * 32768 + RANDOM) % (KMAX - KMIN + 1) ))
  span=$(( hi - lo - 1 )); [ $span -lt 1 ] && span=1; target=$(( lo + 1 + frac * (span - 1) / 1000 ))
  cc "kill $k/$K: burst $lo -> $hi ($*), mode=$KILL_MODE $([ "$KILL_MODE" = height ] && echo "target=$target on $KILL_ON (frac ${frac}/1000)" || echo "delay=${delay}ms") jitter=${jit}ms"
  off=$(log_off); [ "$KILL_MODE" = height ] && watch_start
  "$@"; t0=$(now_ms)
  if [ "${RESTART_OK:-true}" != true ]; then [ "$KILL_MODE" = height ] && watch_stop; return 1; fi
  dl=$(( t0 + SYNC_WAIT_S * 1000 ))
  if [ "$KILL_MODE" = time ]; then sleep "$(awk -v d="$delay" 'BEGIN { printf "%.3f", d / 1000 }')"; trig="time"
  elif watch_until "$target" "$dl"; then trig="height@$HIT"; else trig="timeout"; fi
  sleep "$(awk -v j="$jit" 'BEGIN { printf "%.3f", j / 1000 }')"
  tk=$(now_ms)
  if [ "$CONTROL" = aa ]; then sleep 1; cc "kill $k/$K: A/A control, S not killed"
  else crash S; mark "cc-kill $k"; fi
  [ "$KILL_MODE" = height ] && watch_stop
  # what S had written when it died: its last applied block, best header and indexer height, from its own log
  sl=$(log_last "$off" "$RE_FULL"); sh=$(log_last "$off" "$RE_HDR"); si=-1; [ "$IDX" = 1 ] && si=$(log_last "$off" "$RE_IDX")
  [ "$sl" -lt 0 ] && sl=$lo; mh=$(full_height M)
  # inside the burst: S's last applied block past where the burst started and at least two blocks below M's height at
  # the kill (a follower of a live miner is often one block behind; that is not a burst). With CC_KILL_ON=indexed: the
  # indexer past where it stood before the burst and behind S's own last applied block.
  if [ "$KILL_ON" = indexed ]; then inw=$([ "$si" -gt "$KILL_IDX" ] && [ "$si" -lt "$sl" ] && echo true || echo false)
  else inw=$([ "$sl" -gt "$lo" ] && [ $(( sl + 2 )) -le "${mh:-0}" ] && echo true || echo false); fi
  done_k=$((done_k + 1)); [ "$inw" = true ] && in_k=$((in_k + 1))
  cc "kill $k/$K: trigger=$trig at t=$tk (+$(( tk - t0 ))ms from the burst's start): S last applied=$sl best header=$([ "$sh" -ge 0 ] && echo "$sh" || echo "none logged in the burst")$([ "$IDX" = 1 ] && echo " indexed=$si") M=$mh in_window=$inw"
  jq -cn --argjson k "$k" --arg trig "$trig" --argjson target "$target" --argjson delay "$delay" --argjson jit "$jit" --argjson t "$tk" \
    --argjson rel "$(( tk - t0 ))" --argjson lo "$lo" --argjson hi "$hi" --argjson sl "$sl" --argjson sh "$sh" --argjson si "$si" \
    --argjson mh "${mh:-0}" --argjson inw "$inw" --arg ctl "$CONTROL" \
    '{k: $k, trigger: $trig, target: $target, delay_ms: $delay, jitter_ms: $jit, t_ms: $t, ms_from_burst: $rel, burst_from: $lo, burst_to: $hi,
      s_applied: $sl, s_header: $sh, s_indexed: $si, m_full: $mh, in_window: $inw, killed: ($ctl != "aa")}' >> "$KILLS_JSONL"
  KILL_PF=$sl; [ "$si" -ge 0 ] && KILL_IDX=$si; return 0; }
heal_s(){ heal M S; shape_s; }

# ---- the bursts and the kills ----
mark cc-start
[ "$KILL_ON" = indexed ] && KILL_IDX=$(indexed_of S)
partition M S; wait_backlog "$(full_height S)"
burst 1 "$(full_height S)" "$(full_height M)" heal_s
for ((k = 2; k <= K; k++)); do
  if [ "$CONTROL" = aa ]; then
    [ "$KILL_ON" = indexed ] && KILL_IDX=$(indexed_of S)
    partition M S; wait_backlog "$(full_height S)"; burst "$k" "$(full_height S)" "$(full_height M)" heal_s
  else
    wait_backlog "$KILL_PF"
    # S did not come back: no further kill can be staged, and the outcome is S's (REFUSED unless it answers later)
    burst "$k" "$KILL_PF" "$(full_height M)" restart $((k - 1)) || { cc "S did not come back after kill $((k - 1)); no further kills"; K_EFF=$done_k; break; }
    restart_report
  fi
done
# the last restart, then the controls that change the end state
if [ "$CONTROL" != aa ] && [ "${RESTART_OK:-true}" = true ]; then
  if [ "$CONTROL" = no-restart ]; then cc "control no-restart: S left down after kill $done_k"
  else [ "$ROLE" = miner ] && MINING_OVR[S]=false; wait_backlog "$KILL_PF"; restart "$done_k"
    [ "$RESTART_OK" = true ] && { wait_loaded; sleep 10; restart_report; }; fi
fi
SETTLE_FOLLOWER=S
case "$CONTROL" in
  behind) partition M S; SETTLE_FOLLOWER=R; cc "control behind: S cut from M for the settle" ;;
  fork)   partition M S; SETTLE_FOLLOWER=R; start_mining S 1s >/dev/null; fh=$(full_height S); e=$((SECONDS + 120))
          while [ $SECONDS -lt $e ] && [ "$(full_height S)" -lt $((fh + 3)) ]; do sleep 2; done; stop_mining S >/dev/null
          cc "control fork: S cut from M mined its own blocks $fh -> $(full_height S)" ;;
  no-restart) SETTLE_FOLLOWER=R ;;
esac
[ "$SETTLE_FOLLOWER" = S ] && [ "$came_back_all" = no ] && SETTLE_FOLLOWER=R

# ---- settle: M trickles slowly until the follower is level (rig settle_follow), then pauses ----
mark cc-settle
if settle_follow M "$SETTLE_FOLLOWER" "$(full_height M)" "$SETTLE_S"; then st=ok; else st=no; fi
cc "settle M->$SETTLE_FOLLOWER: $st (${SETTLE_STATE%%:*} after ${SETTLE_WAIT_S}s; after the pause: ${SETTLE_AFTER%%:*})"
# ---- final samples: S, R and M, every 3 s until all three agree or the window ends ----
SAMPLES="$CC_OUT/samples.jsonl"; : > "$SAMPLES"; e=$((SECONDS + FINAL_S))
while :; do
  so="$(node_obs S)"; ro="$(node_obs R)"; mo="$(node_obs M)"; sf=$(jq -r '.full // 0' <<< "$so")
  ar=null; am=null
  if [ "${sf:-0}" -ge 1 ] 2>/dev/null; then ar="$(header_at R "$sf")"; am="$(header_at M "$sf")"
    ar=$([ -n "$ar" ] && jq -cn --arg x "$ar" '$x' || echo null); am=$([ -n "$am" ] && jq -cn --arg x "$am" '$x' || echo null); fi
  jq -cn --argjson t "$(now_ms)" --argjson s "$so" --argjson r "$ro" --argjson m "$mo" --argjson ar "$ar" --argjson am "$am" \
    '{t: $t, nodes: {S: $s, R: $r, M: $m}, subject_at: {R: $ar, M: $am}}' >> "$SAMPLES"
  jq -e -s '.[0] as $s | all(.[1:][]; .answered and $s.answered and .full == $s.full and .bestFull == $s.bestFull and .root == $s.root)' \
    >/dev/null 2>&1 <<< "$so $ro $mo" && break
  [ $SECONDS -ge $e ] && break; sleep 3
done
cc "final: S=$(jq -r '"\(.full)/\(.headers) \(.bestFull // "-" | .[0:12]) \(.root // "-" | .[0:12])"' <<< "$so") R=$(jq -r '"\(.full) \(.bestFull // "-" | .[0:12])"' <<< "$ro") M=$(jq -r '"\(.full) \(.bestFull // "-" | .[0:12])"' <<< "$mo")"

# ---- the indexer, once S, R and M agree ----
IDX_LINE=""
if [ "$IDX" = 1 ] && jq -e '.answered' >/dev/null <<< "$so"; then
  e=$((SECONDS + 180)); while [ $SECONDS -lt $e ]; do
    read -r f1 _ i1 _ <<< "$(idx_heights S)"; read -r f2 _ i2 _ <<< "$(idx_heights R)"
    [ "$i1" = "$f1" ] && [ "$i2" = "$f2" ] && break; sleep 3; done
  for n in S R; do idx_snapshot_global "$n" "$CC_OUT/indexer/$n"; done
  { idx_addresses "$CC_OUT/indexer/S"; idx_addresses "$CC_OUT/indexer/R"; } | sort -u > "$CC_OUT/indexer/addresses.txt"
  for n in S R; do idx_snapshot_finish "$n" "$CC_OUT/indexer/$n" "$CC_OUT/indexer/addresses.txt" "$CC_OUT/indexer/$n.json"; done
  IDX_LINE="$(bash "$here_cc/../indexer-cmp.sh" --label final "$CC_OUT/indexer/R.json" "$CC_OUT/indexer/S.json")"; IDX_LINE="$(head -1 <<< "$IDX_LINE")"
  cc "indexer: $IDX_LINE"
fi

# ---- S's log: unrecoverable lines (judged) and every ERROR line (reported) ----
SLOG="$RIG_LOG_DIR/node_S.log"
grep -E "$FATAL_RE" "$SLOG" 2>/dev/null | grep -v '^\s*at ' | cut -c1-300 > "$CC_OUT/log_fatal.txt"
cc "S log: $(grep -c ' ERROR ' "$SLOG" 2>/dev/null) ERROR line(s), $(wc -l < "$CC_OUT/log_fatal.txt") matching the unrecoverable pattern"
grep ' ERROR ' "$SLOG" 2>/dev/null | sed -E 's/^[0-9:.]+ ERROR +\[[^]]*\] //' | cut -c1-140 | sort | uniq -c | sort -rn | head -5 | sed 's/^/[cc]   /'
sed 's/^/[cc]   fatal: /' "$CC_OUT/log_fatal.txt" | head -5

# ---- the observation and the verdict ----
hf="$(printf '%s\n' "${STAGE_FAIL[@]}" "${HARNESS_FAIL[@]}" | jq -R -s -c 'split("\n") | map(select(length > 0))')"
jq -n --arg ctl "$CONTROL" --argjson kp "$([ "$CONTROL" = aa ] && echo 0 || echo "${K_EFF:-$K}")" --argjson kd "$([ "$CONTROL" = aa ] && echo 0 || echo "$done_k")" \
  --argjson ki "$in_k" --argjson mi "$MIN_IN" --argjson hf "$hf" --slurpfile kills "$KILLS_JSONL" --slurpfile samples "$SAMPLES" \
  --rawfile fatal "$CC_OUT/log_fatal.txt" --arg il "$IDX_LINE" --argjson seed "$SEED" --arg role "$ROLE" \
  '{subject: "S", refs: ["R", "M"], seed: $seed, role: $role,
    staging: {control: $ctl, kills_planned: $kp, kills_done: $kd, kills_in_window: $ki, min_in_window: $mi, harness_fail: $hf},
    kills: $kills, samples: $samples, log_fatal: ($fatal | split("\n") | map(select(length > 0))),
    indexer: (if $il == "" then null else {line: $il} end)}' > "$CC_OUT/obs.json"
VLINE="$(bash "$here_cc/../crash-verdict.sh" "$CC_OUT/obs.json")"
echo "$VLINE"; echo "$VLINE" > "$CC_OUT/verdict.txt"
OUTC="$(cut -d' ' -f2 <<< "$VLINE")"; OUTC="${OUTC%%@*}"
cc "seed=$SEED kills: $(jq -r -s 'map(select(.k) | "#\(.k) \(.trigger) S=\(.s_applied)/\(.s_header) in=\(.in_window)") | join(", ")' "$KILLS_JSONL")"
cc "restarts: $(jq -r -s 'map(select(.restart_after_kill) | "after #\(.restart_after_kill) back=\(.came_back) rest=\(.rest_ms)ms restored=\(.restored_full) (killed at \(.full_at_kill))") | join(", ")' "$KILLS_JSONL")"
want=SAME; case "$CONTROL" in no-restart) want=REFUSED ;; behind) want=STUCK ;; fork) want=DIFF ;; esac
[ "$CONTROL" != none ] && cc "control $CONTROL: expected $want, got $OUTC: $([ "$OUTC" = "$want" ] && echo fired || echo 'DID NOT FIRE')"
case "$OUTC" in SAME) rig_verdict=PASS ;; INCONCLUSIVE) rig_verdict=INCONCLUSIVE; rig_cause=STAGING ;; *) rig_verdict=FAIL ;; esac
if [ "$OUTC" = INCONCLUSIVE ]; then echo "INCONCLUSIVE: crash-consistency ${VLINE#CRASH-CONSISTENCY INCONCLUSIVE }"
else
  b(){ [ "$OUTC" = "$1" ] && echo true || echo false; }
  echo "RESULT_JSON $(jq -cn --argjson v "$VERSIONS" --argjson same "$(b SAME)" --argjson diff "$(b DIFF)" --argjson stuck "$(b STUCK)" \
    --argjson refused "$(b REFUSED)" --argjson logerr "$(b LOGERR)" --argjson kd "$done_k" --argjson ki "$in_k" --argjson seed "$SEED" \
    --argjson upmax "$(jq -s '[.[] | select(.restart_after_kill) | .rest_ms] | max // 0' "$KILLS_JSONL")" \
    --argjson rb "$(jq -s '[.[] | select(.restart_after_kill and .came_back and .restored_full >= 0) | .full_at_kill - .restored_full] | max // 0' "$KILLS_JSONL")" \
    '{schema_version: 1, scenario: "crash-consistency", versions: $v,
      metrics: {same: $same, diff: $diff, stuck: $stuck, refused: $refused, logerr: $logerr, kills: $kd, kills_in_window: $ki,
                max_rest_ms: $upmax, max_rollback: $rb, seed: $seed}}')"
fi
