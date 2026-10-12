# shellcheck shell=bash
# indexer-diff: two JVM nodes with the extra indexer on (ergo.node.extraIndex = true) follow one miner's chain, X on
# PEERYARD_JAR and Y on PEERYARD_JAR_B (the same jar twice is the A/A control); at settled points their /blockchain/...
# answers are read into snapshots (rig/lib/indexer.sh) and compared (rig/indexer-cmp.sh). Topology indexer-diff.json:
# M mines (no indexer), X and Y follow M on their own links; three wallets with different keys.
# Steps:
#   content   M's rewards mature; M pays X and Y three times each, issues a token (wallet /wallet/transaction/send with
#             an asset-issue request) and sends 100 of it to X; X pays Y and Y pays X (each spends a received box).
#   settled   M pauses; once M, X and Y are on one best full block with full height == header height and X's and Y's
#             indexedHeight == full height, both indexers are read and compared. X's snapshot is kept as X0.
#   restart   M mines again and pays X; Y is stopped and started (graceful relaunch, its data kept) while M mines; M
#             pauses; settle and compare. The positive control is then compared: X0 (before this payment and these
#             blocks) against Y's snapshot here, with the comparator's --positive-control (tips may differ); it must
#             come out DIFF, or the run is INCONCLUSIVE (the comparator did not show it can see a difference).
#   fork      Y is cut from M and mines its own branch, with one payment Y -> X confirmed on it; M mines a longer branch;
#             the link is healed and M relaunched (it re-dials Y) and mines on until Y has M's block at the fork height;
#             settle and compare. Y's rollback is checked by its header id at the first forked height before and after.
#             Skipped with INDEXER_DIFF_FORK=0.
# Verdict lines (also in $RIG_LOG_DIR/indexer-verdicts.log): `[indexer-diff] INDEXER-DIFF <point> SAME@..|DIFF@..|
# INCONCLUSIVE ..`. PASS = settled SAME, positive control DIFF, no DIFF at any point; FAIL = a DIFF at any point;
# INCONCLUSIVE = the settled point not settled, or the positive control not DIFF. RESULT_JSON (diffrun contract) is
# printed unless INCONCLUSIVE. Honest nodes, ordinary payments, a partition and a restart only.
here_idx="$(dirname "$(readlink -f "$HOOK")")"
# shellcheck source=rig/lib/indexer.sh
source "$here_idx/../lib/indexer.sh"
CMP="$here_idx/../indexer-cmp.sh"
IDX_OUT="$RIG_LOG_DIR/indexer"; mkdir -p "$IDX_OUT"; VLOG="$RIG_LOG_DIR/indexer-verdicts.log"; : > "$VLOG"
ERG=1000000000
say(){ echo "[indexer-diff] $*"; }
declare -A PT=()            # point label -> SAME / DIFF / INCONCLUSIVE
wait_h(){ local n="$1" min="$2" end=$((SECONDS + ${3:-90})); while [ $SECONDS -lt $end ]; do [ "$(full_height "$n")" -ge "$min" ] 2>/dev/null && { full_height "$n"; return 0; }; sleep 2; done; full_height "$n"; return 1; }
pool_empty(){ local n; for n in M X Y; do [ "$(mempool_size "$n")" = 0 ] || return 1; done; }
# settle_wait <timeout s>: M, X and Y report one best full block, each with full height == header height, and X's and Y's
# indexer at that height. Prints the last reading.
settle_wait(){ local end=$((SECONDS + ${1:-180})) n f h i id ids ok line
  while :; do
    ok=1; ids=""; line=""
    for n in M X Y; do read -r f h i id <<< "$(idx_heights "$n")"; line+="$n=$f/$h/idx$i/${id:0:12} "
      [[ "$f" =~ ^[0-9]+$ && "$f" -ge 1 && "$f" == "$h" ]] || ok=0
      [[ $n == M || "$i" == "$f" ]] || ok=0
      ids+="$id "; done
    [[ $(tr ' ' '\n' <<< "$ids" | grep -v '^$' | sort -u | wc -l) == 1 ]] || ok=0
    SETTLE_LINE="$line"
    [[ $ok == 1 ]] && return 0
    [[ $SECONDS -ge $end ]] && return 1
    sleep 3
  done; }
# compare_point <label>: settle, read X then Y, compare; records PT[label] and the verdict lines
compare_point(){ local label="$1" d="$IDX_OUT/$1" out rc
  mkdir -p "$d"
  if ! settle_wait 180; then
    out="INDEXER-DIFF $label INCONCLUSIVE not settled within 180 s (full/headers/indexed/best id: $SETTLE_LINE)"
  else
    say "$label: settled ($SETTLE_LINE); reading X and Y"
    idx_snapshot_global X "$d/X"; idx_snapshot_global Y "$d/Y"
    { idx_addresses "$d/X"; idx_addresses "$d/Y"; for n in M X Y; do address "$n"; done; } | grep -v '^$' | sort -u > "$d/addresses.txt"
    idx_snapshot_finish X "$d/X" "$d/addresses.txt" "$d/X.json"; idx_snapshot_finish Y "$d/Y" "$d/addresses.txt" "$d/Y.json"
    out="$(bash "$CMP" --label "$label" "$d/X.json" "$d/Y.json")"
    say "$label: $(jq -r '"\(.global.box_count) boxes (\([.boxes[] | select(.spentTransactionId != null)] | length) spent), \(.global.tx_count) transactions, \(.tokens | length) token(s), \(.addresses | length) addresses"' "$d/X.json" 2>/dev/null) in X's snapshot"
  fi
  rc="$(head -1 <<< "$out" | cut -d' ' -f3)"; PT[$label]="${rc%%@*}"
  tee_v "$out"; }
tee_v(){ while IFS= read -r l; do echo "[indexer-diff] $l"; echo "$l" >> "$VLOG"; done <<< "$1"; }   # print and log verdict lines
inconclusive(){ say "INCONCLUSIVE: $1"; rig_verdict=INCONCLUSIVE; rig_cause=${2:-}; echo "[indexer-diff] === INDEXER-DIFF: INCONCLUSIVE ==="; }

VM=$(rest M /info | jq -r '.appVersion // "null"'); VX=$(rest X /info | jq -r '.appVersion // "null"'); VY=$(rest Y /info | jq -r '.appVersion // "null"')
say "M=$VM mines; X=$VX ($(basename "${NODE_JAR[X]}")) and Y=$VY ($(basename "${NODE_JAR[Y]}")) index"
# the indexer answers some seconds after REST does (seen: a check right after bring-up got no number from Y): wait up to 90 s
for n in X Y; do end=$((SECONDS + 90)); ih=""
  while [[ $SECONDS -lt $end ]]; do ih=$(rest "$n" /blockchain/indexedHeight | jq -r '.indexedHeight // empty' 2>/dev/null); [[ "$ih" =~ ^[0-9]+$ ]] && break; sleep 3; done
  [[ "$ih" =~ ^[0-9]+$ ]] || { inconclusive "$n does not serve /blockchain/indexedHeight after 90 s (extraIndex off?): $(rest "$n" /blockchain/indexedHeight | head -c 200)" SETUP_NODE_API; return 0; }; done
AM=$(address M); AX=$(address X); AY=$(address Y)
[[ -n "$AM" && -n "$AX" && -n "$AY" && "$AM" != "$AX" && "$AM" != "$AY" && "$AX" != "$AY" ]] || { inconclusive "wallet addresses missing or shared: M=$AM X=$AX Y=$AY" SETUP_NODE_API; return 0; }

# ---- content
wait_balance M $((100 * ERG)) 300 >/dev/null || { inconclusive "M never had 100 ERG spendable (height $(full_height M))" SETUP_SYNC; return 0; }
acc=0; rej=""
for i in 1 2 3; do for to in X Y; do r=$(pay M "$to" $((5 * ERG))); [[ "$r" =~ ^[0-9a-f]{64}$ ]] && acc=$((acc + 1)) || rej+="M->$to: $r; "; sleep 0.5; done; done
r=$(wallet M /wallet/transaction/send "$(jq -cn --arg a "$AM" '{requests: [{address: $a, ergValue: 1000000, amount: 1000, name: "PYT", description: "peeryard indexer-diff test token", decimals: 0}], fee: 1000000}')" | jq -r 'if type == "string" then . else (.detail // .reason // tojson) end')
[[ "$r" =~ ^[0-9a-f]{64}$ ]] && { acc=$((acc + 1)); say "token issue tx $r"; } || rej+="issue: $r; "
wait_balance X $((15 * ERG)) 240 >/dev/null; wait_balance Y $((15 * ERG)) 240 >/dev/null
r=$(pay X Y $((2 * ERG))); [[ "$r" =~ ^[0-9a-f]{64}$ ]] && acc=$((acc + 1)) || rej+="X->Y: $r; "
r=$(pay Y X $((1 * ERG))); [[ "$r" =~ ^[0-9a-f]{64}$ ]] && acc=$((acc + 1)) || rej+="Y->X: $r; "
TID=""; end=$((SECONDS + 120))
while [[ $SECONDS -lt $end ]]; do TID=$(wallet M /wallet/balances | jq -r '.assets // {} | keys[0] // empty'); [[ -n "$TID" ]] && break; sleep 3; done
if [[ -n "$TID" ]]; then
  r=$(wallet M /wallet/payment/send "$(jq -cn --arg a "$AX" --arg t "$TID" '[{address: $a, value: 1000000, assets: [{tokenId: $t, amount: 100}]}]')" | jq -r 'if type == "string" then . else (.detail // .reason // tojson) end')
  [[ "$r" =~ ^[0-9a-f]{64}$ ]] && acc=$((acc + 1)) || rej+="token M->X: $r; "
else rej+="token never confirmed in M's wallet; "; fi
end=$((SECONDS + 120)); while [[ $SECONDS -lt $end ]] && ! pool_empty; do sleep 3; done
h=$(full_height M); wait_h X $((h + 2)) 60 >/dev/null
say "content: $acc of 10 transactions accepted${rej:+ (rejected: $rej)}; token ${TID:-none}; pools empty: $(pool_empty && echo yes || echo no); M at $(full_height M)"
[[ $acc -ge 8 ]] || { inconclusive "only $acc of 10 transactions accepted" SETUP_SYNC; return 0; }

# ---- settled
stop_mining M >/dev/null
compare_point settled
[[ "${PT[settled]}" == SAME || "${PT[settled]}" == DIFF ]] || { inconclusive "the settled point did not settle" SETUP_SYNC; return 0; }
cp "$IDX_OUT/settled/X.json" "$IDX_OUT/X0.json"

# ---- restart (Y), with blocks and a payment mined while Y is down
start_mining M 1s >/dev/null; wait_h M 1 60 >/dev/null
r=$(pay M X $((1 * ERG))); say "restart: payment M->X ${r:0:64}; relaunching Y while M mines"
relaunch Y; sleep 5
h=$(full_height M); wait_h Y "$h" 120 >/dev/null
end=$((SECONDS + 60)); while [[ $SECONDS -lt $end ]] && ! pool_empty; do sleep 3; done
stop_mining M >/dev/null
compare_point restart
POS="$(bash "$CMP" --label posctl --positive-control --show 3 "$IDX_OUT/X0.json" "$IDX_OUT/restart/Y.json" 2>&1)"
tee_v "$POS"
posctl=false; [[ "$(head -1 <<< "$POS" | cut -d' ' -f3)" == DIFF@* ]] && posctl=true
[[ $posctl == true ]] || { inconclusive "positive control (X before the restart-point payment vs Y after) did not come out DIFF" POSCTL; return 0; }

# ---- fork (Y on a losing branch)
rolled=false; PT[fork]=SKIPPED
if [[ "${INDEXER_DIFF_FORK:-1}" == 1 ]]; then
  h0=$(full_height M); partition M Y
  start_mining Y 3s >/dev/null; wait_h Y $((h0 + 1)) 90 >/dev/null
  r=$(pay Y X $((1 * ERG))); say "fork: cut M<->Y at $h0; Y mines its branch; payment Y->X on it: ${r:0:64}"
  end=$((SECONDS + 90)); while [[ $SECONDS -lt $end ]]; do [[ "$(mempool_size Y)" == 0 && "$(full_height Y)" -ge $((h0 + 3)) ]] && break; sleep 3; done
  stop_mining Y >/dev/null; hy=$(wait_h Y $((h0 + 1)) 60)
  start_mining M 1s >/dev/null; hm=$(wait_h M $((hy + 3)) 150); stop_mining M >/dev/null; hm=$(wait_h M "$hm" 60)
  yid0=$(header_at Y $((h0 + 1))); mid=$(header_at M $((h0 + 1))); sc=$(same_chain M Y)
  say "fork: Y's branch to $hy, M's to $hm; at $((h0 + 1)) Y=${yid0:0:16} M=${mid:0:16}; same_chain: ${sc:0:60}"
  if [[ "${sc%%@*}" != DIFF || -z "$yid0" || "$yid0" == "$mid" ]]; then
    PT[fork]=INCONCLUSIVE; tee_v "INDEXER-DIFF fork INCONCLUSIVE no fork staged ($sc)"
  else
    heal M Y; start_mining M 3s >/dev/null
    end=$((SECONDS + 180)); while [[ $SECONDS -lt $end ]]; do
      [[ "$(header_at Y $((h0 + 1)))" == "$mid" && "$(full_height Y)" -ge "$hm" ]] && break; sleep 3; done
    stop_mining M >/dev/null
    yid1=$(header_at Y $((h0 + 1))); [[ "$yid1" == "$mid" && "$yid1" != "$yid0" ]] && rolled=true
    say "fork: after the heal Y has ${yid1:0:16} at $((h0 + 1)) (rolled back to M's branch: $rolled)"
    compare_point fork
  fi
fi

# ---- verdict
ns=0; nd=0; ni=0
for p in settled restart fork; do case "${PT[$p]:-}" in SAME) ns=$((ns + 1)) ;; DIFF) nd=$((nd + 1)) ;; INCONCLUSIVE) ni=$((ni + 1)) ;; esac; done
unr=0; for n in M X Y; do [ "$(rest $n /info | jq -r '.appVersion // "null"')" = null ] && unr=$((unr + 1)); done
say "points: settled=${PT[settled]} restart=${PT[restart]:-} fork=${PT[fork]} (Y rolled back: $rolled); positive control DIFF: $posctl"
if [[ $nd -gt 0 ]]; then rig_verdict=FAIL; elif [[ "${PT[settled]}" == SAME ]]; then rig_verdict=PASS; else rig_verdict=INCONCLUSIVE; fi
b(){ [[ "${PT[$1]:-}" == SAME ]] && echo true || echo false; }
echo "RESULT_JSON $(jq -cn --arg M "$VM" --arg X "$VX" --arg Y "$VY" --argjson s "$(b settled)" --argjson r "$(b restart)" --argjson f "$(b fork)" \
  --argjson pc "$posctl" --argjson rb "$rolled" --argjson ns $ns --argjson nd $nd --argjson ni $ni --argjson u $unr --arg jv "$(${PEERYARD_JAVA:-java} -version 2>&1 | head -1)" \
  '{schema_version: 1, scenario: "indexer-diff", runtime: {java: $jv}, versions: {M: $M, X: $X, Y: $Y},
    metrics: {agree: ($nd == 0), settled_same: $s, restart_same: $r, fork_same: $f, fork_rolled_back: $rb, posctl_diff: $pc,
              points_same: $ns, points_diff: $nd, points_inconclusive: $ni, unresponsive_after: $u}}')"
echo "[indexer-diff] === INDEXER-DIFF: $rig_verdict ==="
