# storage-rent-2598: a miner that collects storage rent itself (ergoplatform/ergo#2598, "Storage rent collection in the
# node": ergo.node.storageRentCollection = true, which needs ergo.node.extraIndex = true) next to release followers.
# Do the blocks it mines with its own claim transactions pass a v6.0.7 node, and do all nodes end on one state root?
#   C   mining, #2598 jar (PEERYARD_JAR_C), extraIndex = true, storageRentCollection = true (false in the control)
#   F1  follower, v6.0.7 jar (PEERYARD_JAR_F1)
#   F2  follower, #2598 jar (PEERYARD_JAR_F2), storageRentCollection = false
# Every jar carries both devnet test patches (patches/test/: storage period 60 blocks, the txRentDistinctOutputs rule
# active from height 30); otherwise nothing ages within a run, and a follower with the mainnet period would evaluate
# a claim's empty proof against the box's script. Holder boxes owned by a foreign key (the public test key, secret
# scalar 1, which no node's wallet holds) are made with rent_box from C's wallet: covered and not-covered values, a
# box with registers R4/R5, one with a large R4 that makes its fee exceed its value, and two carrying a token. C mines
# past the period; every claim in the chain is then audited from F1's copy of the blocks (rent_audit), and the
# holders' boxes are looked up among the claims.
#   PEERYARD_STORAGE_PERIOD   the build's period (default 60)
#   SR2598_CONTROL=off        the control: C with storageRentCollection = false (0 claims; agreement as before)
#   SR2598_WINDOW_S           seconds to wait for the holder boxes to be claimed after they expire (default 180)
# PASS (collection on) = at least one claim; every claim checked against the rule with no failure and no unknown box;
# every holder box claimed; same_state C F1 and C F2 SAME at a settled height after the claims; no "invalid" or
# SemanticallyFailed line in F1's or F2's log. PASS (control) = no claim in the chain, the holder boxes still unspent,
# both same_state SAME, no such log line.
# Under diffrun (DIFFRUN_ROLE set; diffrun/scenarios/storage-rent-2598.json): C runs the role's jar with collection
# on, F1 the base jar, F2 the candidate jar. The base role (a release jar + the test patches, which has no
# storageRentCollection setting and ignores the key) is held to the control's expectations, the candidate role to
# collection's; the hook prints one RESULT_JSON whose "pass" is that verdict, with the counts beside it.
P=${PEERYARD_STORAGE_PERIOD:-60}; export PEERYARD_STORAGE_PERIOD=$P
WIN=${SR2598_WINDOW_S:-180}
note(){ echo "[sr2598] $*"; }
COLLECT=true; EXPECT=claims; NAME=STORAGE-RENT-2598
if [ "${SR2598_CONTROL:-}" = off ]; then COLLECT=false; EXPECT=none; NAME="STORAGE-RENT-2598 CONTROL"; fi
if [ "${DIFFRUN_ROLE:-}" = base ]; then EXPECT=none; NAME="STORAGE-RENT-2598 (diffrun base)"; fi
inconclusive(){ echo "$NAME: INCONCLUSIVE ($*)"; rig_verdict=INCONCLUSIVE; }
CONF_OVR[C]="ergo.node.extraIndex=true
ergo.node.storageRentCollection=$COLLECT"
launch C; wait_up C || { inconclusive "C never answered"; return 0; }
note "C launched: extraIndex=true storageRentCollection=$COLLECT; versions C=$(rest C /info | jq -r .appVersion) F1=$(rest F1 /info | jq -r .appVersion) F2=$(rest F2 /info | jq -r .appVersion); storage period $P"
end=$((SECONDS+120)); while [ $SECONDS -lt $end ]; do case "$(same_chain C F1)$(same_chain C F2)" in SAME@*SAME@*) break;; esac; sleep 2; done
note "floor: C-F1 $(same_chain C F1 | cut -c1-14), C-F2 $(same_chain C F2 | cut -c1-14)"
wait_balance C 40000000000 300 >/dev/null || { inconclusive "C unfunded"; return 0; }
ftree="0008cd0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798"
faddr=$(rest C "/utils/ergoTreeToAddress/$ftree" | jq -r '.address // empty')
[ -n "$faddr" ] || { inconclusive "no holder address"; return 0; }
tid=$(rent_issue C 1000 SRT) || { inconclusive "token issue refused"; return 0; }
note "holder address ${faddr:0:16}...; test token ${tid:0:16}...; C at $(full_height C)"
r4small="0e0a$(printf '%020x' 42)"                       # Coll[Byte], 10 bytes
r5int="0402"                                               # Int 1 (zigzag VLQ)
r4big="0eac02$(printf 'ab%.0s' $(seq 300))"                # Coll[Byte], 300 bytes (length 300 as VLQ: ac 02)
BOXES="$RIG_LOG_DIR/holder_boxes.txt"; : > "$BOXES"
mk(){ local label="$1" v="$2" as="${3:-[]}" rg="${4:-}" bc
  bc=$(rent_box C "$v" "$faddr" "$as" "$rg") || { note "holder box $label: NOT CREATED"; return 1; }
  echo "$label $bc $v" >> "$BOXES"; note "holder box $label: $bc value $v"; }
mk dust-0.01 10000000
mk small-0.05 50000000
mk covered-1 1000000000
mk covered-5 5000000000
mk regs-R4R5-1 1000000000 '[]' "{\"R4\":\"$r4small\",\"R5\":\"$r5int\"}"
mk bigR4-notcovered-0.2 200000000 '[]' "{\"R4\":\"$r4big\"}"
mk token-covered-1 1000000000 "[{\"tokenId\":\"$tid\",\"amount\":10}]"
mk token-notcovered-0.02 20000000 "[{\"tokenId\":\"$tid\",\"amount\":5}]"
nb=$(wc -l < "$BOXES"); maxh=$(awk '{print $3}' "$BOXES" | sort -n | tail -1)
note "$nb holder boxes; newest creation height $maxh; C at $(full_height C) (the first box of the run expires at height $P)"
[ "$nb" -ge 1 ] || { inconclusive "no holder box created"; return 0; }
# the audit's size formula against the node's own serialization, on every holder box (F1, the release node)
end=$((SECONDS+60)); while [ $SECONDS -lt $end ] && [ "$(full_height F1)" -lt "$maxh" ]; do sleep 2; done
fac=$(storage_fee_factor F1); sizebad=0
while read -r label box ch v; do s=$(box_size_check F1 "$box"); note "  $label size computed/actual: $s; fee $(( fac * ${s%% *} )) vs value $v"
  [ "${s%% *}" = "${s##* }" ] || sizebad=$((sizebad+1)); done < "$BOXES"
note "storageFeeFactor $fac; size formula mismatches: $sizebad"
target=$((maxh + P + 3))
note "mining to $target (every holder box expired + 3)"
end=$((SECONDS+600)); while [ $SECONDS -lt $end ] && [ "$(full_height C)" -lt "$target" ]; do sleep 3; done
unspent(){ local u=0; while read -r label box ch v; do rest F1 "/utxo/byId/$box" | jq -e '.boxId' >/dev/null 2>&1 && u=$((u+1)); done < "$BOXES"; echo "$u"; }
if [ "$EXPECT" = claims ]; then
  end=$((SECONDS+WIN)); while [ $SECONDS -lt $end ] && [ "$(unspent)" -gt 0 ]; do sleep 3; done
fi
note "C at $(full_height C); holder boxes unspent on F1: $(unspent)/$nb"
hs=$(( $(full_height C) + 2 ))
settle_follow C F1 "$hs" 150; sf=$?
note "settle C-F1: $SETTLE_STATE (after pause: $SETTLE_AFTER, ${SETTLE_WAIT_S}s)"
s2=""; end=$((SECONDS+90)); while [ $SECONDS -lt $end ]; do s2=$(same_state C F2); case "$s2" in SAME@*) break;; esac; sleep 3; done
s1=$(same_state C F1)
note "same_state C F1: $s1"
note "same_state C F2: $s2"
hf=$(full_height F1)
rest F1 /utxo/genesis > "$RIG_LOG_DIR/genesis_boxes.json"
rent_blocks F1 1 "$hf" "$RIG_LOG_DIR/blocks_F1.jsonl"
rent_audit "$RIG_LOG_DIR/blocks_F1.jsonl" "$fac" "$RIG_LOG_DIR/genesis_boxes.json" > "$RIG_LOG_DIR/rent_audit.jsonl"
sum=$(jq -c 'select(.summary) | .summary' "$RIG_LOG_DIR/rent_audit.jsonl")
note "blocks 1..$hf read from F1: $(wc -l < "$RIG_LOG_DIR/blocks_F1.jsonl"); audit: $sum"
jq -r 'select(.summary | not) | "  claim h=\(.height) tx=\(.tx[0:12]) box=\(.input[0:12]) age=\(.age) size=\(.size) value=\(.box_value) fee=\(.fee) \(.branch // "unknown") tokens=\(.tokens) regs=\(.registers) ok=\(.ok)\(if .branch == "recreated" then " out=\(.out_value) [value \(.value_ok) tree \(.tree_ok) tokens \(.tokens_ok) regs \(.registers_ok) height \(.height_ok)]" else "" end)"' \
  "$RIG_LOG_DIR/rent_audit.jsonl" | head -60
held=0; hok=0
while read -r label box ch v; do
  c=$(jq -c --arg b "$box" 'select(.input == $b)' "$RIG_LOG_DIR/rent_audit.jsonl" | head -1)
  if [ -n "$c" ]; then held=$((held+1)); [ "$(jq -r .ok <<< "$c")" = true ] && hok=$((hok+1))
    note "holder $label: claimed at $(jq -r .height <<< "$c") ($(jq -r .branch <<< "$c"), ok=$(jq -r .ok <<< "$c"))"
  else note "holder $label: not claimed"; fi
done < "$BOXES"
claims=$(jq -r '.claim_inputs' <<< "$sum"); ctx=$(jq -r '.claim_txs' <<< "$sum"); failed=$(jq -r '.failed' <<< "$sum"); unk=$(jq -r '.unknown' <<< "$sum"); young=$(jq -r '.younger_than_period' <<< "$sum")
note "claim transactions $ctx with $claims claimed inputs in C's blocks (C is the only miner); holder boxes claimed $held/$nb (rule ok $hok)"
bad=0
for f in F1 F2; do
  [ -s "$RIG_LOG_DIR/node_$f.log" ] || { inconclusive "no log for $f, so the log search could not run"; return 0; }
  lines=$(grep -E 'SemanticallyFailed|[Ii]nvalid' "$RIG_LOG_DIR/node_$f.log" 2>/dev/null)
  n=0; [ -n "$lines" ] && n=$(printf '%s\n' "$lines" | wc -l)
  note "$f log lines matching invalid|SemanticallyFailed: $n"; [ "$n" -gt 0 ] && { printf '%s\n' "$lines" | head -5 | cut -c1-300 | sed 's/^/    /'; bad=$((bad+n)); }
done
ok_state(){ case "$1" in SAME@*) h=${1#SAME@}; [ "${h%%:*}" -ge "$hs" ] ;; *) return 1 ;; esac; }
agree=false; ok_state "$s1" && ok_state "$s2" && agree=true
note "agreement (both SAME at >= $hs): $agree; size formula mismatches $sizebad"
if [ "$EXPECT" = claims ]; then
  if [ "$claims" -ge 1 ] && [ "$failed" = 0 ] && [ "$unk" = 0 ] && [ "$young" = 0 ] && [ "$held" = "$nb" ] && [ "$agree" = true ] && [ "$bad" = 0 ] && [ "$sizebad" = 0 ]; then
    echo "$NAME: PASS (C mined $ctx claim txs / $claims claimed boxes, all within the rule; $held/$nb holder boxes claimed; F1 (v6.0.7) and F2 on C's state root: $(cut -c1-24 <<< "$s1"))"; rig_verdict=PASS
  else echo "$NAME: FAIL (claims $claims, rule failures $failed, unknown $unk, younger $young, holders claimed $held/$nb, agreement $agree, log lines $bad, size mismatches $sizebad)"; rig_verdict=FAIL; fi
else
  if [ "$claims" = 0 ] && [ "$(unspent)" = "$nb" ] && [ "$sizebad" = 0 ] && [ "$agree" = true ] && [ "$bad" = 0 ]; then
    echo "$NAME: PASS (no collection expected: 0 claims, $nb/$nb holder boxes unspent, F1 and F2 on C's state root: $(cut -c1-24 <<< "$s1"))"; rig_verdict=PASS
  else echo "$NAME: FAIL (claims $claims, holder boxes unspent $(unspent)/$nb, agreement $agree, log lines $bad, size mismatches $sizebad)"; rig_verdict=FAIL; fi
fi
if [ -n "${DIFFRUN_ROLE:-}" ]; then
  echo "RESULT_JSON $(jq -cn --arg C "$(rest C /info | jq -r '.appVersion // "null"')" --arg F1 "$(rest F1 /info | jq -r '.appVersion // "null"')" \
    --arg F2 "$(rest F2 /info | jq -r '.appVersion // "null"')" --argjson s "$sum" --argjson h "$held" --argjson nb "$nb" \
    --argjson ag "$agree" --argjson ll "$bad" --argjson sb "$sizebad" --argjson pass "$([ "$rig_verdict" = PASS ] && echo true || echo false)" \
    '{schema_version: 1, scenario: "storage-rent-2598", versions: {C: $C, F1: $F1, F2: $F2},
      metrics: {claims: $s.claim_inputs, claim_txs: $s.claim_txs, rule_failures: ($s.failed + $s.unknown + $s.younger_than_period),
                holders: $nb, holders_claimed: $h, agreement: $ag, log_lines: $ll, size_mismatches: $sb, pass: $pass}}')"
fi
[ "$sf" = 0 ] || note "settle_follow returned $sf"
