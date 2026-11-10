# cache-window-fork: does a node adopt a competing chain that is heavier in total but whose first header above the
# node's tip is lighter than the node's tip? PASS = staged and C switched to A's chain; FAIL = staged and C did not
# switch within CWF_MEAS_S; INCONCLUSIVE = the staging did not happen (A heavier already at C's tip + 1, or never
# heavier in total).
#   prefix  - C mines a shared chain past CWF_PREFIX_H (above 128, so a fork deeper than 16 blocks still has a common
#             point in the V2 sync summary's 128-block offset); A follows. C's mining is paused; A syncs to C's tip h0.
#   split   - A-C cut. C mines its fork from h0 at CWF_POLL until it is CWF_DEPTH deep, then stops at hc. Only then,
#             after CWF_A_DELAY_S more, does A start mining its fork from h0 (CWF_A_POLL): its retarget reads the pause, so its blocks tend to
#             carry less difficulty. A mines until its fork work (difficulty summed from nBits over h0+1..) exceeds
#             C's over h0+1..hc by CWF_MARGIN_PCT percent and A is at least hc + 2.
#   staging - recorded, not gated: wa1 = A's work over h0+1..hc+1 against wc = C's over h0+1..hc ("lighter at
#             tip+1" when wa1 <= wc), and wa = A's total at the heal.
#   heal    - the link heals (re-dialled), A keeps mining. For up to CWF_MEAS_S: C's headers/full heights and best
#             header id, and whether C's log has "Chain switch:". Ends CWF_TAIL_S after C is on A's chain.
# Env: CWF_PREFIX_H (300: past the devnet's version-2 activation at 128, whose fixed difficulty 32 at 129..144 stays in the 8-epoch retarget window until ~273), CWF_DEPTH (20), CWF_POLL (2s), CWF_A_POLL (2s), CWF_MARGIN_PCT (2), CWF_MEAS_S (300),
#      CWF_TAIL_S (30), CWF_STAGE_S (900), CWF_A_DELAY_S (180: the wait between C's stop and A's start).
PREFIX_H=${CWF_PREFIX_H:-300}; DEPTH=${CWF_DEPTH:-20}; POLL=${CWF_POLL:-2s}; APOLL=${CWF_A_POLL:-2s}
DELAY=${CWF_A_DELAY_S:-180}; MARGIN=${CWF_MARGIN_PCT:-2}; MEAS_S=${CWF_MEAS_S:-300}; TAIL_S=${CWF_TAIL_S:-30}; STAGE_S=${CWF_STAGE_S:-900}
W="$RIG_LOG_DIR/cwf"; mkdir -p "$W"
say(){ echo "[cwf] $(date +%T.%3N) $*"; }
cwf_inconclusive(){ say "INCONCLUSIVE: $2"; rig_verdict=INCONCLUSIVE; rig_cause=$1; say "=== CACHE-WINDOW-FORK: $rig_verdict ==="; }
wait_h(){ local n="$1" min="$2" end=$((SECONDS + ${3:-90})); while [ $SECONDS -lt $end ]; do [ "$(full_height "$n")" -ge "$min" ] 2>/dev/null && { full_height "$n"; return 0; }; sleep 2; done; full_height "$n"; return 1; }
hdr_height(){ rest "$1" /info | jq -r '.headersHeight // 0'; }
best_hdr(){ rest "$1" /info | jq -r '.bestHeaderId // empty'; }
full_synced(){ local n="$1" h; h=$(full_height "$n"); [ "${h:-0}" -ge 1 ] && [ "$h" = "$(hdr_height "$n")" ]; }
# fork_work <node> <h_from> <h_to>: the sum of the difficulties the headers' nBits encode over those heights of the
# node's best chain (the node's score adds exactly these)
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
# above_margin <a> <b> <pct>: a > b * (100 + pct) / 100
above_margin(){ python3 -c 'import sys; a, b, p = map(int, sys.argv[1:]); sys.exit(0 if a * 100 > b * (100 + p) else 1)' "$1" "$2" "$3"; }
nbits_list(){ local n="$1" h id; for ((h = $2; h <= $3; h++)); do id=$(header_at "$n" "$h"); printf '%s:%s ' "$h" "$([ -n "$id" ] && rest "$n" "/blocks/$id/header" | jq -r '.nBits')"; done; echo; }

# ---- prefix ----
say "prefix>=$PREFIX_H depth=$DEPTH poll C=$POLL A=$APOLL margin=${MARGIN}%; appVersion C=$(rest C /info | jq -r .appVersion) A=$(rest A /info | jq -r .appVersion)"
end=$((SECONDS + 1500)); ok=no
while [ $SECONDS -lt $end ]; do
  [ "$(full_height C)" -ge "$PREFIX_H" ] 2>/dev/null && [ "$(same_chain C A | cut -c1-4)" = SAME ] && { ok=yes; break; }; sleep 3
done
[ $ok = yes ] || { cwf_inconclusive PREFIX_NOT_REACHED "C=$(full_height C) A=$(full_height A)"; return 0; }
hpre=$(full_height C); stop_mining C; hshared=$(wait_h C "$hpre")
end=$((SECONDS + 120)); ok=no
while [ $SECONDS -lt $end ]; do
  [ "$(full_height A)" -ge "$hshared" ] 2>/dev/null && full_synced A && [ "$(same_chain A C | cut -c1-4)" = SAME ] && { ok=yes; break; }; sleep 3
done
[ $ok = yes ] || { cwf_inconclusive NOT_SETTLED "A full=$(full_height A) hdr=$(hdr_height A) C=$hshared"; return 0; }
h0=$hshared; say "settled at shared height $h0"

# ---- split: C's fork first, then A's ----
mark cwf-partition; partition A C
start_mining C "$POLL"; wait_h C "$h0" >/dev/null
end=$((SECONDS + STAGE_S)); ok=no
while [ $SECONDS -lt $end ]; do [ "$(full_height C)" -ge $((h0 + DEPTH)) ] 2>/dev/null && { ok=yes; break; }; sleep 1; done
hc_pre=$(full_height C); stop_mining C; hc=$(wait_h C "$hc_pre")
[ $ok = yes ] || { cwf_inconclusive C_FORK_SHORT "C at $(full_height C), want $((h0 + DEPTH))"; return 0; }
wc_=$(fork_work C $((h0 + 1)) "$hc"); sc_info=$(rest C /info | jq -c '{headersHeight, fullHeight, headersScore, bestHeaderId}')
say "C's fork: heights $((h0 + 1))..$hc (depth $((hc - h0))), work $wc_; C /info $sc_info"
echo "C nBits: $(nbits_list C $((h0 + 1)) "$hc")" > "$W/c_nbits"

say "A starts mining after a further ${DELAY} s (its retarget reads the pause)"; sleep "$DELAY"
start_mining A "$APOLL"; wait_h A "$h0" >/dev/null
end=$((SECONDS + STAGE_S)); ok=no; wa1=""; wa=""
while [ $SECONDS -lt $end ]; do
  ha=$(full_height A)
  if [ -z "$wa1" ] && [ "${ha:-0}" -ge $((hc + 1)) ] 2>/dev/null; then wa1=$(fork_work A $((h0 + 1)) $((hc + 1))); fi
  if [ -n "$wa1" ] && [ "${ha:-0}" -ge $((hc + 2)) ] 2>/dev/null; then
    wa=$(fork_work A $((h0 + 1)) "$ha"); above_margin "$wa" "$wc_" "$MARGIN" && { ok=yes; break; }
  fi
  sleep 2
done
[ $ok = yes ] || { cwf_inconclusive A_NOT_HEAVIER "A=$(full_height A) work ${wa:-?} against C's $wc_"; return 0; }
ha=$(full_height A); wa=$(fork_work A $((h0 + 1)) "$ha")
echo "A nBits: $(nbits_list A $((h0 + 1)) "$ha")" > "$W/a_nbits"
sc=$(same_chain A C); [ "${sc%%@*}" = DIFF ] || { cwf_inconclusive NO_FORK "A and C not on different chains before the heal: $sc"; return 0; }
lighter=no; bigger "$wa1" "$wc_" || lighter=yes
say "STAGING h0=$h0 hc=$hc ha=$ha wc=$wc_ wa1=$wa1 (A over $((h0 + 1))..$((hc + 1))) wa=$wa lighter_at_tip1=$lighter heavier_total=yes; A /info $(rest A /info | jq -c '{headersHeight, fullHeight, headersScore, bestHeaderId}')"

# ---- heal and measure ----
CLOG="$RIG_LOG_DIR/node_C.log"; cl0=$(wc -l < "$CLOG")
t_heal_ms=$(date +%s%3N); say "HEAL at $(date +%T.%3N) (epoch ms $t_heal_ms); C log line $cl0"
mark cwf-heal; heal A C
( relink 90 A C || say "WARN relink did not connect A-C" ) &
printf 't_ms\tt_s\tc_hdr\tc_full\tc_best\ta_full\tchain\n' > "$W/samples.tsv"
switched=""; on_a=""; end=$((SECONDS + MEAS_S))
while [ $SECONDS -lt $end ]; do
  ch=$(hdr_height C); cf=$(full_height C); cb=$(best_hdr C); af=$(full_height A); s=$(same_chain A C | cut -c1-4)
  tn=$(date +%s%3N); ts=$(( (tn - t_heal_ms) / 1000 ))
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$tn" "$ts" "$ch" "$cf" "${cb:0:16}" "$af" "$s" >> "$W/samples.tsv"
  if [ -z "$switched" ] && tail -n +"$((cl0 + 1))" "$CLOG" | grep -q 'Chain switch:'; then switched=$tn; say "C's log has a chain switch by +$(( tn - t_heal_ms )) ms (C hdr=$ch full=$cf)"; fi
  if [ -z "$on_a" ] && [ "$s" = SAME ] && [ "${cf:-0}" -gt "$hc" ] 2>/dev/null; then on_a=$tn; say "C on A's chain above hc at +$(( tn - t_heal_ms )) ms (C full=$cf, A=$af)"; fi
  [ -n "$on_a" ] && [ $(( (tn - on_a) / 1000 )) -ge "$TAIL_S" ] && break
  sleep 2
done
sed -n "$((cl0 + 1)),\$p" "$CLOG" | grep -E 'Chain switch:|orphan|Orphan|Rollback|rollback|Best header|best header' | head -400 > "$W/C_lines.log"
ch=$(hdr_height C); cf=$(full_height C); s=$(same_chain A C)
say "RESULT h0=$h0 hc=$hc ha=$ha wc=$wc_ wa1=$wa1 wa=$wa lighter_at_tip1=$lighter switch=$([ -n "$on_a" ] && echo yes || echo no) switch_log_ms=$([ -n "$switched" ] && echo $((switched - t_heal_ms)) || echo none) on_a_ms=$([ -n "$on_a" ] && echo $((on_a - t_heal_ms)) || echo none) final C hdr=$ch full=$cf A full=$(full_height A) same_chain=${s:0:40}"
if [ "$lighter" != yes ]; then rig_verdict=INCONCLUSIVE; rig_cause=A_HEAVIER_AT_TIP1
elif [ -n "$on_a" ]; then rig_verdict=PASS
else rig_verdict=FAIL; rig_cause=NO_SWITCH; fi
say "=== CACHE-WINDOW-FORK: $rig_verdict ==="
