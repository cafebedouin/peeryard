# reorg-invalid-mempool: a deep reorg that returns many transactions to the pool which the winning chain has made
# invalid, and what the node's mempool cleanup does with them afterwards (measurement, not a pass/fail claim about
# the node: PASS means the staging happened as designed).
#
# A and C hold one wallet (the rig's default mnemonic for both), so both can sign for the same boxes. D and E are
# addresses only (the P2PK addresses of the public keys G and 2G), never nodes.
#   prefix   - C mines a shared chain past height RIM_PREFIX_H (above 128, so a fork deeper than 16 blocks still has
#              a common point in the V2 sync summary's 128-block offset), A follows. C splits matured rewards into
#              K boxes of RIM_V nanoERG (self-payments of RIM_SPLIT_OUTS outputs each), confirmed in the prefix.
#   settle   - C's mining is paused; A fully syncs to C's tip.
#   pre-sign - per box, tx1 (to D, signed by C's wallet) and tx2 (to E, signed by A's wallet), both spending exactly
#              that box (/wallet/transaction/generate with inputsRaw), nothing submitted yet.
#   split    - A-C cut. Both mine from the cut, C at RIM_FORK_POLL with every tx1 over REST, A at RIM_A_POLL (faster)
#              with every tx2. C stops once all tx1 are confirmed on its fork and it is RIM_MIN_DEPTH deep. A mines on
#              until all tx2 are confirmed, it is 2 blocks above C, and its fork outweighs C's (difficulty summed from
#              nBits); then the link heals (A keeps mining, so blocks keep arriving at C and trigger its cleanup runs).
#   measure  - every second for up to RIM_MEAS_S: C's pool size, how many tx1 are in it, C on A's chain or not.
#              Ends RIM_TAIL_S after the pool first holds no tx1 following the switch.
# The node log lines CLEANUP-RUN / ROLLBACK-TXS (an instrumentation patch; absent on a plain jar), "Chain switch:"
# and "Initiating mempool cleanup" from C's log after the heal are copied to $RIG_LOG_DIR/rim_C_lines.log.
# PASS = every tx1 confirmed on C's fork, every tx2 on A's fork, C on A's chain after the heal with every tx2 on its
# final chain and no tx1 on it. INCONCLUSIVE (with a cause) when any staging step did not happen.
# Env: RIM_K (500; K + K/5 + 10 boxes are made, see the split), RIM_V (10000000), RIM_FEE (1000000), RIM_PREFIX_H (140), RIM_SPLIT_OUTS (250),
#      RIM_FORK_POLL (2s), RIM_MEAS_S (300), RIM_TAIL_S (60), RIM_STAGE_S (900: the cap on each fork's mining wait),
#      RIM_MIN_DEPTH (20: C mines on past its last tx1 until its fork is at least this deep), RIM_A_POLL (1500ms).
K=${RIM_K:-500}; V=${RIM_V:-10000000}; FEE=${RIM_FEE:-1000000}; PAYV=$((V - FEE))
PREFIX_H=${RIM_PREFIX_H:-140}; OUTS=${RIM_SPLIT_OUTS:-250}; FPOLL=${RIM_FORK_POLL:-2s}
MEAS_S=${RIM_MEAS_S:-300}; TAIL_S=${RIM_TAIL_S:-60}; STAGE_S=${RIM_STAGE_S:-900}; MIN_DEPTH=${RIM_MIN_DEPTH:-20}; APOLL=${RIM_A_POLL:-1500ms}
W="$RIG_LOG_DIR/rim"; mkdir -p "$W"
say(){ echo "[rim] $(date +%T.%3N) $*"; }
rim_inconclusive(){ say "INCONCLUSIVE: $2"; rig_verdict=INCONCLUSIVE; rig_cause=$1; say "=== REORG-INVALID-MEMPOOL: $rig_verdict ==="; }
wait_h(){ local n="$1" min="$2" end=$((SECONDS + ${3:-90})); while [ $SECONDS -lt $end ]; do [ "$(full_height "$n")" -ge "$min" ] 2>/dev/null && { full_height "$n"; return 0; }; sleep 2; done; full_height "$n"; return 1; }
hdr_height(){ rest "$1" /info | jq -r '.headersHeight // 0'; }
full_synced(){ local n="$1" h; h=$(full_height "$n"); [ "${h:-0}" -ge 1 ] && [ "$h" = "$(hdr_height "$n")" ]; }
# pool_ids <node>: the pooled transaction ids; fails (prints nothing) when the reply is not a JSON array, so a missed
# read is never taken for an empty pool
pool_ids(){ local b; b=$(ip netns exec "${NS[$1]}" curl -s --max-time 10 "http://127.0.0.1:${REST[$1]}/transactions/unconfirmed/transactionIds") || return 1
  jq -e 'type == "array"' <<< "$b" >/dev/null 2>&1 || return 1; jq -r '.[]' <<< "$b"; }
# chain_txids <node> <h_from> <h_to>: every transaction id in the node's best chain over those heights
chain_txids(){ local n="$1" h id; for ((h = $2; h <= $3; h++)); do id=$(header_at "$n" "$h"); [ -n "$id" ] || continue
  ip netns exec "${NS[$n]}" curl -s --max-time 10 "http://127.0.0.1:${REST[$n]}/blocks/$id/transactions" | jq -r '.transactions[]?.id'; done; }
# per-height transaction counts (coinbase included), for the block-capacity record
chain_counts(){ local n="$1" h; for ((h = $2; h <= $3; h++)); do printf '%s:%s ' "$h" "$(block_txs "$n" "$h")"; done; echo; }
# score <node>: /info headersScore (null, read as 0, until the node applies a header after its launch)
score(){ rest "$1" /info | jq -r '.headersScore // 0'; }
# fork_work <node> <h_from> <h_to>: the sum of the difficulties the headers' nBits encode over those heights of the
# node's best chain (the node's score adds exactly these); bigger <a> <b>: a > b as integers
fork_work(){ local n="$1" h id; for ((h = $2; h <= $3; h++)); do id=$(header_at "$n" "$h"); [ -n "$id" ] && rest "$n" "/blocks/$id/header" | jq -r '.nBits'; done \
  | python3 -c '
import sys
t = 0
for line in sys.stdin:
    c = int(line); size = (c >> 24) & 0xFF; m = c & 0x7FFFFF
    v = m >> (8 * (3 - size)) if size <= 3 else m << (8 * (size - 3))
    t += -v if c & 0x800000 else v
print(t)'; }
bigger(){ python3 -c 'import sys; sys.exit(0 if int(sys.argv[1]) > int(sys.argv[2]) else 1)' "$1" "$2"; }
# count_in <idfile> <setfile>: lines of idfile that are in setfile
count_in(){ grep -cFxf "$2" "$1" 2>/dev/null || true; }
# submit_all <node> <txfile> <outfile>: POST every transaction line to /transactions, one reply per line
submit_all(){ local n="$1" line r acc=0 rej=0
  : > "$3"
  while IFS= read -r line; do
    r=$(printf '%s' "$line" | ip netns exec "${NS[$n]}" curl -s --max-time 30 -X POST -H 'Content-Type: application/json' \
          --data-binary @- "http://127.0.0.1:${REST[$n]}/transactions")
    if [[ "$r" =~ ^\"[0-9a-f]{64}\"$ ]]; then acc=$((acc + 1)); else rej=$((rej + 1)); echo "REJECT ${r:0:200}" >> "$3"; fi
  done < "$2"
  echo "$acc $rej"; }

# ---- prefix ----
say "K=$K V=$V fee=$FEE prefix>=$PREFIX_H fork_poll=$FPOLL; appVersion C=$(rest C /info | jq -r .appVersion) A=$(rest A /info | jq -r .appVersion)"
need=$((K * V + 2000000000))
end=$((SECONDS + 600)); ok=no
while [ $SECONDS -lt $end ]; do
  cb=$(balance C)
  if [ "$(full_height C)" -ge "$PREFIX_H" ] 2>/dev/null && [ "${cb:-0}" -ge "$need" ] 2>/dev/null && [ "$(same_chain C A | cut -c1-4)" = SAME ]; then ok=yes; break; fi
  sleep 3
done
[ $ok = yes ] || { rim_inconclusive PREFIX_NOT_REACHED "C=$(full_height C) A=$(full_height A) balance=$(balance C) need=$need"; return 0; }
say "prefix reached: C=$(full_height C) A=$(full_height A) balance=$(balance C)"
D=$(rest C /utils/rawToAddress/0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798 | jq -r '.address // empty')
E=$(rest C /utils/rawToAddress/02c6047f9441ed7d6d3045406e95c07cd85c778e4b8cef3ca7abac09b95c709ee5 | jq -r '.address // empty')
ME=$(address C)
[[ -n "$D" && -n "$E" && -n "$ME" && "$ME" == "$(address A)" ]] || { rim_inconclusive NO_ADDRESSES "D=$D E=$E C=$ME A=$(address A)"; return 0; }
say "D=$D E=$E wallet(A=C)=$ME"

# split matured rewards into K boxes of V, a few self-payments of OUTS outputs each, all confirmed in the prefix
# the wallet may spend an earlier split's unconfirmed outputs as inputs of the next one, so a few more boxes than K
# are made and the first K still unspent are used
KS=$((K + K / 5 + 10))
hs0=$(full_height C); : > "$W/split_ids"; left=$KS; i=0
while [ "$left" -gt 0 ]; do
  n=$(( left < OUTS ? left : OUTS )); i=$((i + 1))
  reqs=$(jq -nc --arg a "$ME" --argjson v "$V" --argjson k "$n" '[range($k) | {address: $a, value: $v}]')
  r=$(wallet C /wallet/payment/send "$reqs")
  id=$(jq -r 'if type == "string" then . else empty end' <<< "$r" 2>/dev/null)
  [[ "$id" =~ ^[0-9a-f]{64}$ ]] || { rim_inconclusive SPLIT_REJECTED "split $i refused: ${r:0:300}"; return 0; }
  echo "$id" >> "$W/split_ids"; left=$((left - n)); sleep 0.5
done
say "split: $i transactions sent from height $hs0"
end=$((SECONDS + 240)); ok=no
while [ $SECONDS -lt $end ]; do pool_ids C > "$W/c_pool" && [ ! -s "$W/c_pool" ] && { ok=yes; break; }; sleep 2; done
[ $ok = yes ] || { rim_inconclusive SPLIT_NOT_CONFIRMED "C's pool not empty after the split: $(pool_ids C | wc -l)"; return 0; }
hs1=$(wait_h C $(( $(full_height C) + 3 )) 60)
# the boxes: outputs of value V of the mined split transactions, read from C's blocks
: > "$W/boxes"
for ((h = hs0; h <= hs1; h++)); do
  id=$(header_at C "$h"); [ -n "$id" ] || continue
  ip netns exec "${NS[C]}" curl -s --max-time 10 "http://127.0.0.1:${REST[C]}/blocks/$id/transactions" \
    | jq -r --rawfile s "$W/split_ids" --argjson v "$V" '($s | split("\n") | map(select(length > 0))) as $ids
        | .transactions[]? | select(.id as $t | $ids | index($t)) | .outputs[] | select(.value == $v) | .boxId' >> "$W/boxes"
done
nb=$(sort -u "$W/boxes" | wc -l)
[ "$nb" -eq "$KS" ] || { rim_inconclusive SPLIT_BOXES "found $nb boxes of value $V in the split transactions, want $KS"; return 0; }
say "split confirmed: $nb boxes of $V in heights $hs0..$hs1"

# ---- settle: C paused, A fully synced to the shared tip ----
hpre=$(full_height C); stop_mining C; hshared=$(wait_h C "$hpre")
end=$((SECONDS + 120)); ok=no
while [ $SECONDS -lt $end ]; do
  [ "$(full_height A)" -ge "$hshared" ] 2>/dev/null && full_synced A && [ "$(same_chain A C | cut -c1-4)" = SAME ] && { ok=yes; break; }; sleep 3
done
[ $ok = yes ] || { rim_inconclusive NOT_SETTLED "A full=$(full_height A) hdr=$(hdr_height A) C=$hshared"; return 0; }
h0=$hshared; say "settled at shared height $h0"

# ---- pre-sign tx1 (C, to D) and tx2 (A, to E) per box ----
: > "$W/tx1.jsonl"; : > "$W/tx2.jsonl"; bad=0; spent=0; got=0; t_gen=$SECONDS
while IFS= read -r box; do
  [ "$got" -ge "$K" ] && break
  raw=$(rest A "/utxo/byIdBinary/$box" | jq -r '.bytes // empty')
  [ -n "$raw" ] || { spent=$((spent + 1)); echo "$box" >> "$W/boxes_not_in_utxo"; continue; }
  t1=$(wallet C /wallet/transaction/generate "{\"requests\":[{\"address\":\"$D\",\"value\":$PAYV}],\"inputsRaw\":[\"$raw\"],\"fee\":$FEE}")
  t2=$(wallet A /wallet/transaction/generate "{\"requests\":[{\"address\":\"$E\",\"value\":$PAYV}],\"inputsRaw\":[\"$raw\"],\"fee\":$FEE}")
  if jq -e --arg b "$box" '(.inputs | length) == 1 and .inputs[0].boxId == $b' <<< "$t1" >/dev/null 2>&1 \
     && jq -e --arg b "$box" '(.inputs | length) == 1 and .inputs[0].boxId == $b' <<< "$t2" >/dev/null 2>&1; then
    jq -c . <<< "$t1" >> "$W/tx1.jsonl"; jq -c . <<< "$t2" >> "$W/tx2.jsonl"; got=$((got + 1))
  else bad=$((bad + 1)); [ $bad -le 3 ] && say "generate failed for $box: ${t1:0:200} / ${t2:0:200}"; fi
done < "$W/boxes"
jq -r .id "$W/tx1.jsonl" > "$W/tx1_ids"; jq -r .id "$W/tx2.jsonl" > "$W/tx2_ids"
n1=$(sort -u "$W/tx1_ids" | wc -l); n2=$(sort -u "$W/tx2_ids" | wc -l); nx=$(count_in "$W/tx1_ids" "$W/tx2_ids")
say "pre-signed: tx1 $n1, tx2 $n2, ids in both $nx, failures $bad, boxes skipped as not in A's UTXO set $spent ($((SECONDS - t_gen)) s)"
[ "$n1" -eq "$K" ] && [ "$n2" -eq "$K" ] && [ "$nx" -eq 0 ] || { rim_inconclusive PRESIGN "tx1=$n1 tx2=$n2 shared=$nx"; return 0; }

# ---- split: both forks mined from the partition on, C with every tx1, A (faster poll) with every tx2 ----
# Staging precondition: A's fork outweighs C's (work summed from nBits). Both forks start together and A mines faster,
# so neither retarget reads a pause.
mark rim-partition; partition A C
start_mining C "$FPOLL"; wait_h C "$h0" >/dev/null
start_mining A "$APOLL"; wait_h A "$h0" >/dev/null
( submit_all C "$W/tx1.jsonl" "$W/tx1_submit" > "$W/tx1_r" ) & sp1=$!
( submit_all A "$W/tx2.jsonl" "$W/tx2_submit" > "$W/tx2_r" ) & sp2=$!
wait "$sp1" "$sp2"; r1=$(cat "$W/tx1_r"); r2=$(cat "$W/tx2_r")
say "submitted: tx1 to C accepted/rejected $r1; tx2 to A accepted/rejected $r2"
[ "${r1%% *}" -eq "$K" ] || { head -3 "$W/tx1_submit"; rim_inconclusive TX1_REJECTED "$r1"; return 0; }
[ "${r2%% *}" -eq "$K" ] || { head -3 "$W/tx2_submit"; rim_inconclusive TX2_REJECTED "$r2"; return 0; }
end=$((SECONDS + STAGE_S)); ok=no
while [ $SECONDS -lt $end ]; do
  pool_ids C > "$W/c_pool" && [ "$(count_in "$W/c_pool" "$W/tx1_ids")" = 0 ] && [ "$(full_height C)" -ge $((h0 + MIN_DEPTH)) ] 2>/dev/null && { ok=yes; break; }; sleep 2; done
hc_pre=$(full_height C); stop_mining C; hc=$(wait_h C "$hc_pre")
[ $ok = yes ] || { rim_inconclusive TX1_NOT_MINED "tx1 still pooled on C: $(count_in "$W/c_pool" "$W/tx1_ids")"; return 0; }
chain_txids C $((h0 + 1)) "$hc" > "$W/c_fork_txids"
c_on=$(count_in "$W/tx1_ids" "$W/c_fork_txids")
say "C's fork: heights $((h0 + 1))..$hc (depth $((hc - h0))), tx1 on it $c_on/$K, txs in fork $(wc -l < "$W/c_fork_txids")"
echo "C fork counts: $(chain_counts C $((h0 + 1)) "$hc")" > "$W/c_fork_counts"
[ "$c_on" -eq "$K" ] || { rim_inconclusive TX1_NOT_ON_FORK "$c_on/$K"; return 0; }
wc_=$(fork_work C $((h0 + 1)) "$hc")
end=$((SECONDS + STAGE_S)); ok=no; wa1=""
while [ $SECONDS -lt $end ]; do
  if [ -z "$wa1" ] && [ "$(full_height A)" -ge $((hc + 1)) ] 2>/dev/null; then
    wa1=$(fork_work A $((h0 + 1)) $((hc + 1))); say "fork work: C over $((h0 + 1))..$hc = $wc_; A over $((h0 + 1))..$((hc + 1)) = $wa1"
    bigger "$wa1" "$wc_" || { rim_inconclusive A_NOT_HEAVIER "A's fork work ($wa1) is not above C's ($wc_)"; return 0; }
  fi
  pool_ids A > "$W/a_pool" && [ "$(count_in "$W/a_pool" "$W/tx2_ids")" = 0 ] && [ -n "$wa1" ] && [ "$(full_height A)" -ge $((hc + 2)) ] 2>/dev/null && { ok=yes; break; }; sleep 2
done
[ $ok = yes ] || { rim_inconclusive TX2_NOT_MINED "tx2 pooled on A $(count_in "$W/a_pool" "$W/tx2_ids"), A=$(full_height A) C=$hc"; return 0; }
ha=$(full_height A)
sc=$(same_chain A C); [ "${sc%%@*}" = DIFF ] || { rim_inconclusive NO_FORK "A and C not on different chains before the heal: $sc"; return 0; }
echo "A fork counts: $(chain_counts A $((h0 + 1)) "$ha")" > "$W/a_fork_counts"
say "A's fork at $ha (C at $hc, lead $((ha - hc))); headersScore A=$(score A) (C's reads null after its relaunch); fork before heal: ${sc:0:40}"

# ---- heal and measure ----
CLOG="$RIG_LOG_DIR/node_C.log"; cl0=$(wc -l < "$CLOG")
t_heal_ms=$(date +%s%3N); say "HEAL at $(date +%T.%3N) (epoch ms $t_heal_ms); C log line $cl0"
mark rim-heal; heal A C
( relink 90 A C || say "WARN relink did not connect A-C" ) &
printf 't_ms\tt_s\tpool\ttx1_pooled\tc_full\tc_hdr\ta_full\tchain\n' > "$W/samples.tsv"
switched=""; t_clear=""; max1=0; end=$((SECONDS + MEAS_S))
while [ $SECONDS -lt $end ]; do
  pool_ids C > "$W/c_pool" || { echo "$(date +%s%3N) pool read failed" >> "$W/sample_misses"; sleep 1; continue; }
  p=$(wc -l < "$W/c_pool"); p1=$(count_in "$W/c_pool" "$W/tx1_ids")
  cf=$(full_height C); ch=$(hdr_height C); af=$(full_height A); s=$(same_chain A C | cut -c1-4)
  tn=$(date +%s%3N); ts=$(( (tn - t_heal_ms) / 1000 ))  # tn: when the sample's reads ended
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$tn" "$ts" "$p" "$p1" "$cf" "$ch" "$af" "$s" >> "$W/samples.tsv"
  [ "$p1" -gt "$max1" ] && max1=$p1
  # the switch is taken from C's own log line, not from /info: /info shows the new best block a moment before the
  # view holder installs the updated pool, so a sample in between reads the old pool. A sample counts as after the
  # switch only if it started after the line was seen.
  if [ -z "$switched" ] && tail -n +"$((cl0 + 1))" "$CLOG" | grep -q 'Chain switch:'; then switched=$tn; say "C's log has its chain switch by +$(( tn - t_heal_ms )) ms (this sample: pool $p, tx1 pooled $p1, not counted)"
  elif [ -n "$switched" ] && [ -z "$t_clear" ] && [ "$p1" = 0 ]; then t_clear=$tn; say "no tx1 pooled at +$(( tn - t_heal_ms )) ms (max seen $max1), pool $p"; fi
  [ -n "$t_clear" ] && [ $(( (tn - t_clear) / 1000 )) -ge "$TAIL_S" ] && break
  sleep 1
done
sed -n "$((cl0 + 1)),\$p" "$CLOG" | grep -E 'CLEANUP-RUN|ROLLBACK-TXS|Chain switch:|Initiating mempool cleanup|Mempool validation failed|OutOfMemory' > "$RIG_LOG_DIR/rim_C_lines.log"
say "C log lines after the heal: $(grep -c CLEANUP-RUN "$RIG_LOG_DIR/rim_C_lines.log") CLEANUP-RUN, $(grep -c ROLLBACK-TXS "$RIG_LOG_DIR/rim_C_lines.log") ROLLBACK-TXS, $(grep -c 'Chain switch:' "$RIG_LOG_DIR/rim_C_lines.log") chain switch"
# prefixed so a wrapper that forwards only "[...]" lines (diffrun's rig-example) keeps them
grep -E 'ROLLBACK-TXS|Chain switch:' "$RIG_LOG_DIR/rim_C_lines.log" | head -8 | sed -E 's/^.*(ROLLBACK-TXS|Chain switch:)/[rim] node C: \1/'
grep -E 'CLEANUP-RUN' "$RIG_LOG_DIR/rim_C_lines.log" | awk '$0 !~ /due=0 /' | head -12 | sed -E 's/^.*(CLEANUP-RUN)/[rim] node C: \1/'

cf=$(full_height C)
chain_txids C $((h0 + 1)) "$cf" > "$W/c_final_txids"
t2on=$(count_in "$W/tx2_ids" "$W/c_final_txids"); t1on=$(count_in "$W/tx1_ids" "$W/c_final_txids")
say "C's final chain ($((h0 + 1))..$cf): tx2 on it $t2on/$K, tx1 on it $t1on"
say "RESULT K=$K h0=$h0 hc=$hc ha=$ha depth_c=$((hc - h0)) depth_a=$((ha - h0)) switched_ms=$([ -n "$switched" ] && echo $((switched - t_heal_ms)) || echo none) clear_ms=$([ -n "$t_clear" ] && echo $((t_clear - t_heal_ms)) || echo none) max_tx1_pooled=$max1 tx2_on_chain=$t2on/$K tx1_on_chain=$t1on"
if [ -z "$switched" ]; then rim_inconclusive NO_SWITCH "C never joined A's chain within $MEAS_S s"; return 0; fi
if ! grep -q ROLLBACK-TXS "$RIG_LOG_DIR/rim_C_lines.log"; then rim_inconclusive NO_ROLLBACK_LINE "no ROLLBACK-TXS line in C's log after the heal (not an instrumented jar?)"; return 0; fi
if [ "$t2on" -eq "$K" ] && [ "$t1on" -eq 0 ]; then rig_verdict=PASS; else rig_verdict=FAIL; fi
say "=== REORG-INVALID-MEMPOOL: $rig_verdict ==="
