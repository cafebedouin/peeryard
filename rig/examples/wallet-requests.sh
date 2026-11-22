# shellcheck shell=bash
# wallet-requests: how two wallet nodes answer the same wallet requests, valid and malformed, at the route level.
# Topology indexer-diff.json: M mines; X on PEERYARD_JAR and Y on PEERYARD_JAR_B follow M, each with its own wallet
# mnemonic. Written for ergoplatform/ergo#2390 (wallet request token ids decoded only at 32 bytes; the transaction
# request subtype chosen by its fields, with no fallback to another subtype after a decoding error).
# Steps:
#   fund     M's rewards mature; M pays X and Y 20 ERG each; confirmed.
#   token    X and Y each issue one token (1000 units) through /wallet/transaction/send; confirmed; TOK = that node's
#            own token id, from its /wallet/balances.
#   cases    on X and on Y, once each, with T = M's first address and TOK the node's own token (TOK31 = its first 62 hex
#            characters, TOK33 = TOK + "00", NOHEX = "zz" + its last 62 characters):
#            valid, /wallet/transaction/generate (fee 1000000): V1 payment {T, 1 ERG}; V2 V1 with assets null; V3 V1 with
#              1 TOK; V4 issuance of 5; V5 burn of 1 TOK; V6 assetsToBurn null; V7 V1 then V5 in one holder;
#            valid, /wallet/boxes/collect: V8 {1 ERG, TOK: 1};
#            malformed, /wallet/transaction/generate: B1 V3 with TOK31; B2 with TOK33; B3 with NOHEX; B4 V5 with TOK31;
#              B5 V5 with NOHEX; B6 V1 with its address's last character changed; B7 {address T} (no value); B8 {};
#            malformed, /wallet/boxes/collect: B9 keyed by TOK31; B10 by NOHEX;
#            malformed, /wallet/payment/send: B11 V3's payment with TOK31; B12 with NOHEX.
#   send     after the cases, B6 once through /wallet/transaction/send on each node (SEND line; x/y_malformed_sent: the
#            transaction reached the node's pool).
#   Generate builds and signs without sending; payment/send is given only requests both node versions are expected to
#   refuse. The wallets' confirmed balances and assets and both mempools are read before and after the cases and must
#   not move.
# Checks, per node: W1 every valid case answered 200 with the expected request-derived outputs (value and TOK to T,
# new tokens, TOK left in the outputs); W2 every malformed case answered non-200. Across nodes: W3 every valid case with
# the same status and the same request-derived outputs. Lines: `[wallet-requests] CASE <node> <case> http=<code>
# <summary>`; `SUMMARY <node> ...` and the log-difference line last. RESULT_JSON carries x_valid_ok, x_malformed_refused,
# x_malformed_built (a count), x_malformed_sent, the same for y, valid_same and x_pass. Honest nodes, ordinary wallet requests only.
OUT="$RIG_LOG_DIR/wallet-requests"; mkdir -p "$OUT"
ERG=1000000000; FEE=1000000
say(){ echo "[wallet-requests] $*"; }
inconclusive(){ say "INCONCLUSIVE: $1"; rig_verdict=INCONCLUSIVE; rig_cause=${2:-}; echo "[wallet-requests] === WALLET-REQUESTS: INCONCLUSIVE ==="; }
pool_empty(){ local n; for n in M X Y; do [ "$(mempool_size "$n")" = 0 ] || return 1; done; }
# call <node> <path> <json>: POST with the API key; prints "<http code> <body>" on one line (body compacted when JSON)
call(){ local f; f=$(mktemp "$OUT/resp.XXXXXX")
  local code; code=$(ip netns exec "${NS[$1]}" curl -s --max-time 120 -o "$f" -w '%{http_code}' -X POST -H "api_key: $API_KEY" \
    -H 'Content-Type: application/json' --data "$3" "http://127.0.0.1:${REST[$1]}$2")
  printf '%s ' "$code"; jq -c . "$f" 2>/dev/null || tr -d '\n' < "$f"; echo; rm -f "$f"; }
stab(){ local n; for n in X Y; do printf '%s=%s ' "$n" "$(wallet "$n" /wallet/balances | jq -c '{balance, assets}' 2>/dev/null)"; done
  printf 'pools=%s/%s/%s' "$(mempool_size M)" "$(mempool_size X)" "$(mempool_size Y)"; }

VX=$(rest X /info | jq -r '.appVersion // "null"'); VY=$(rest Y /info | jq -r '.appVersion // "null"')
say "X=$VX ($(basename "${NODE_JAR[X]}")) Y=$VY ($(basename "${NODE_JAR[Y]}"))"
T=$(address M); [[ -n "$T" ]] || { inconclusive "M has no wallet address" SETUP_NODE_API; return 0; }
TT=$(rest M "/script/addressToTree/$T" | jq -r '.tree // empty'); [[ -n "$TT" ]] || { inconclusive "no tree for M's address" SETUP_NODE_API; return 0; }

# ---- fund
wait_balance M $((50 * ERG)) 300 >/dev/null || { inconclusive "M never had 50 ERG spendable (height $(full_height M))" SETUP_SYNC; return 0; }
for n in X Y; do r=$(pay M "$n" $((20 * ERG))); [[ "$r" =~ ^[0-9a-f]{64}$ ]] || { inconclusive "M->$n: $r" SETUP_SYNC; return 0; }; sleep 1; done
for n in X Y; do wait_balance "$n" $((20 * ERG)) 240 >/dev/null || { inconclusive "$n never saw its 20 ERG" SETUP_SYNC; return 0; }; done

# ---- token: one issuance per node, through the transaction-request dispatcher of that node's own jar
declare -A TOK
for n in X Y; do
  r=$(call "$n" /wallet/transaction/send "{\"requests\":[{\"amount\":1000,\"name\":\"RT\",\"description\":\"review token\",\"decimals\":0}],\"fee\":$FEE}")
  say "issue $n: $(cut -c1-120 <<< "$r")"; [[ "${r%% *}" == 200 ]] || { inconclusive "$n refused the issuance: $r" SETUP_SYNC; return 0; }
done
end=$((SECONDS + 240)); while [[ $SECONDS -lt $end ]]; do
  for n in X Y; do TOK[$n]=$(wallet "$n" /wallet/balances | jq -r '.assets // {} | to_entries | map(select(.value == 1000)) | .[0].key // empty'); done
  [[ -n "${TOK[X]}" && -n "${TOK[Y]}" ]] && pool_empty && break; sleep 3; done
[[ "${TOK[X]}" =~ ^[0-9a-f]{64}$ && "${TOK[Y]}" =~ ^[0-9a-f]{64}$ ]] || { inconclusive "no confirmed token on X/Y (${TOK[X]:-none}/${TOK[Y]:-none})" SETUP_SYNC; return 0; }
for n in X Y; do b=$(wallet "$n" /wallet/balances)
  [[ $(jq -r '.assets | length' <<< "$b") == 1 && $(jq -r '.balance' <<< "$b") -ge $((15 * ERG)) ]] || { inconclusive "$n setup: $b" SETUP_SYNC; return 0; }; done
pool_empty || { inconclusive "pools not empty before the cases" SETUP_SYNC; return 0; }
say "setup: T=$T X token ${TOK[X]:0:12} Y token ${TOK[Y]:0:12}; $(stab | sed -E 's/([0-9a-f]{12})[0-9a-f]{52}/\1/g')"

# ---- cases
holder(){ echo "{\"requests\":$1,\"fee\":$FEE}"; }
pay1(){ echo "{\"address\":\"$T\",\"value\":$ERG${1:-}}"; }                  # pay1 [,extra fields]
tokarr(){ echo "[{\"tokenId\":\"$1\",\"amount\":1}]"; }
BADT="${T%?}$([[ "${T: -1}" == a ]] && echo b || echo a)"
# summary <tok> < tx json: the request-derived outputs (value and TOK to T, tokens other than TOK, TOK in all outputs)
summary_tx(){ jq -c --arg t "$TT" --arg k "$1" '{n_out: (.outputs | length),
  to_T: [.outputs[] | select(.ergoTree == $t) | {v: .value, tok: ([.assets[]? | select(.tokenId == $k) | .amount] | add // 0)}],
  new_tokens: [.outputs[].assets[]? | select(.tokenId != $k) | .amount], tok_out: ([.outputs[].assets[]? | select(.tokenId == $k) | .amount] | add // 0)}'; }
summary_boxes(){ jq -c --arg k "$1" '{boxes: (.boxes | length), tok: ([.boxes[].assets[]? | select(.tokenId == $k) | .amount] | add // 0)}'; }
declare -A ST SM; CASES_V=(V1 V2 V3 V4 V5 V6 V7 V8); CASES_B=(B1 B2 B3 B4 B5 B6 B7 B8 B9 B10 B11 B12)
before="$(stab)"
for n in X Y; do k=${TOK[$n]}; k31=${k:0:62}; k33="${k}00"; nh="zz${k:2}"
  declare -A REQ=(
    [V1]="G $(holder "[$(pay1)]")" [V2]="G $(holder "[$(pay1 ',"assets":null')]")" [V3]="G $(holder "[$(pay1 ",\"assets\":$(tokarr "$k")")]")"
    [V4]="G $(holder '[{"amount":5,"name":"RT2","description":"second","decimals":0}]')"
    [V5]="G $(holder "[{\"assetsToBurn\":$(tokarr "$k")}]")" [V6]="G $(holder '[{"assetsToBurn":null}]')"
    [V7]="G $(holder "[$(pay1),{\"assetsToBurn\":$(tokarr "$k")}]")"
    [V8]="C {\"targetBalance\":$ERG,\"targetAssets\":{\"$k\":1}}"
    [B1]="G $(holder "[$(pay1 ",\"assets\":$(tokarr "$k31")")]")" [B2]="G $(holder "[$(pay1 ",\"assets\":$(tokarr "$k33")")]")"
    [B3]="G $(holder "[$(pay1 ",\"assets\":$(tokarr "$nh")")]")"
    [B4]="G $(holder "[{\"assetsToBurn\":$(tokarr "$k31")}]")" [B5]="G $(holder "[{\"assetsToBurn\":$(tokarr "$nh")}]")"
    [B6]="G $(holder "[{\"address\":\"$BADT\",\"value\":$ERG}]")" [B7]="G $(holder "[{\"address\":\"$T\"}]")" [B8]="G $(holder '[{}]')"
    [B9]="C {\"targetBalance\":$ERG,\"targetAssets\":{\"$k31\":1}}" [B10]="C {\"targetBalance\":$ERG,\"targetAssets\":{\"$nh\":1}}"
    [B11]="P [$(pay1 ",\"assets\":$(tokarr "$k31")")]" [B12]="P [$(pay1 ",\"assets\":$(tokarr "$nh")")]" )
  for c in "${CASES_V[@]}" "${CASES_B[@]}"; do r=${REQ[$c]}; kind=${r%% *}; body=${r#* }
    case $kind in G) path=/wallet/transaction/generate ;; C) path=/wallet/boxes/collect ;; P) path=/wallet/payment/send ;; esac
    resp="$(call "$n" "$path" "$body")"; code=${resp%% *}; payload=${resp#* }
    echo "$n $c $path $body" >> "$OUT/requests.txt"; echo "$n $c $resp" >> "$OUT/responses.txt"
    if [[ $code == 200 ]]; then
      case $kind in G) s=$(summary_tx "$k" <<< "$payload" 2>/dev/null) ;; C) s=$(summary_boxes "$k" <<< "$payload" 2>/dev/null) ;; P) s="sent $(cut -c1-16 <<< "$payload")" ;; esac
    else s="refused: $(jq -r '(.detail // .reason // tostring)' <<< "$payload" 2>/dev/null | tr -d '\n' | sed -E 's/[0-9a-f]{16,}/<h>/g; s/[1-9A-HJ-NP-Za-km-z]{40,}/<addr>/g' | cut -c1-110)"; fi
    ST[$n.$c]=$code; SM[$n.$c]="$s"; say "CASE $n $c http=$code $s"
  done
  unset REQ
done
after="$(stab)"

# ---- checks
exp_ok(){ local s="$2"; case $1 in   # exp_ok <case> <summary>: the request-derived outputs a valid case must show
  V1|V2) [[ $(jq -c '.to_T' <<< "$s") == "[{\"v\":$ERG,\"tok\":0}]" && $(jq -c '.new_tokens' <<< "$s") == "[]" ]] ;;
  V3) [[ $(jq -c '.to_T' <<< "$s") == "[{\"v\":$ERG,\"tok\":1}]" && $(jq -r '.tok_out' <<< "$s") == 1000 ]] ;;
  V4) [[ $(jq -c '.new_tokens' <<< "$s") == "[5]" && $(jq -c '.to_T' <<< "$s") == "[]" ]] ;;
  V5) [[ $(jq -r '.tok_out' <<< "$s") == 999 && $(jq -c '.to_T' <<< "$s") == "[]" ]] ;;
  V6) [[ $(jq -c '.to_T' <<< "$s") == "[]" && $(jq -c '.new_tokens' <<< "$s") == "[]" ]] ;;
  V7) [[ $(jq -c '.to_T' <<< "$s") == "[{\"v\":$ERG,\"tok\":0}]" && $(jq -r '.tok_out' <<< "$s") == 999 ]] ;;
  V8) [[ $(jq -r '.tok' <<< "$s") -ge 1 ]] ;;
  *) return 1 ;; esac 2>/dev/null; }
declare -A VOK=( [X]=true [Y]=true ) BOK=( [X]=true [Y]=true ) BUILT=( [X]=0 [Y]=0 )
for n in X Y; do
  for c in "${CASES_V[@]}"; do { [[ ${ST[$n.$c]} == 200 ]] && exp_ok "$c" "${SM[$n.$c]}"; } || { VOK[$n]=false; say "W1 $n $c FAIL"; }; done
  for c in "${CASES_B[@]}"; do [[ ${ST[$n.$c]} == 200 ]] && { BOK[$n]=false; BUILT[$n]=$((BUILT[$n] + 1)); }; done
done
same=true; for c in "${CASES_V[@]}"; do
  [[ ${ST[X.$c]} == "${ST[Y.$c]}" && "${SM[X.$c]}" == "${SM[Y.$c]}" ]] || { same=false; say "W3 $c DIFF x=${ST[X.$c]} ${SM[X.$c]} y=${ST[Y.$c]} ${SM[Y.$c]}"; }; done
[[ "$before" == "$after" ]] || { inconclusive "wallets or pools moved during the cases: before $before after $after" SETUP_SYNC; return 0; }

# ---- send: B6 (the corrupted address) once through /wallet/transaction/send on each node, after the stability record,
# since this one may spend: what the node does with it, and, when it answers 200, whether the transaction reached its
# pool and what it pays.
declare -A SENT=( [X]=false [Y]=false )
for n in X Y; do resp="$(call "$n" /wallet/transaction/send "$(holder "[{\"address\":\"$BADT\",\"value\":$ERG}]")")"; code=${resp%% *}; payload=${resp#* }
  echo "$n S6 $resp" >> "$OUT/responses.txt"; s="refused"
  if [[ $code == 200 ]]; then id=$(jq -r 'if type == "string" then . else empty end' <<< "$payload"); s="tx ${id:0:16} not in pool"
    end=$((SECONDS + 30)); while [[ $SECONDS -lt $end ]]; do tx=$(rest "$n" "/transactions/unconfirmed/byTransactionId/$id")
      if jq -e '.outputs' <<< "$tx" >/dev/null 2>&1; then SENT[$n]=true; s="tx ${id:0:16} in pool $(summary_tx "${TOK[$n]}" <<< "$tx")"; break; fi; sleep 2; done; fi
  say "SEND $n S6 http=$code $s"
done
# Summary, printed last so a caller that keeps only the tail of this output still has it.
for n in X Y; do
  say "SUMMARY $n valid: $(for c in "${CASES_V[@]}"; do printf '%s=%s ' "$c" "${ST[$n.$c]}"; done)"
  say "SUMMARY $n malformed: $(for c in "${CASES_B[@]}"; do printf '%s=%s ' "$c" "${ST[$n.$c]}"; done)built=${BUILT[$n]}; S6 sent ${SENT[$n]}"
done
logsig(){ grep -E ' (ERROR|WARN) ' "$RIG_LOG_DIR/node_$1.log" 2>/dev/null | sed -E 's/^[0-9:.]+ +//; s/\[[^]]*\]//; s/[0-9a-f]{16,}/<h>/g; s/[0-9]+/<n>/g' | sort -u; }
say "LOGS ERROR/WARN lines: X=$(grep -cE ' (ERROR|WARN) ' "$RIG_LOG_DIR/node_X.log") Y=$(grep -cE ' (ERROR|WARN) ' "$RIG_LOG_DIR/node_Y.log"); only on X: $(comm -23 <(logsig X) <(logsig Y) | paste -sd'|' - | cut -c1-300); only on Y: $(comm -13 <(logsig X) <(logsig Y) | paste -sd'|' - | cut -c1-300)"
say "verdict: X valid ok ${VOK[X]}, malformed refused ${BOK[X]} (built ${BUILT[X]}); Y valid ok ${VOK[Y]}, malformed refused ${BOK[Y]} (built ${BUILT[Y]}); valid same $same"
if [[ ${VOK[X]} == true && ${VOK[Y]} == true && ${BOK[X]} == true && ${BOK[Y]} == true && $same == true ]]; then rig_verdict=PASS; else rig_verdict=FAIL; fi
echo "RESULT_JSON $(jq -cn --arg X "$VX" --arg Y "$VY" --argjson xv "${VOK[X]}" --argjson yv "${VOK[Y]}" --argjson xb "${BOK[X]}" --argjson yb "${BOK[Y]}" \
  --argjson xn "${BUILT[X]}" --argjson yn "${BUILT[Y]}" --argjson s "$same" --argjson xs "${SENT[X]}" --argjson ys "${SENT[Y]}" --arg jv "$(${PEERYARD_JAVA:-java} -version 2>&1 | head -1)" \
  '{schema_version: 1, scenario: "wallet-requests", runtime: {java: $jv}, versions: {X: $X, Y: $Y},
    metrics: {x_valid_ok: $xv, y_valid_ok: $yv, x_malformed_refused: $xb, y_malformed_refused: $yb,
              x_malformed_built: $xn, y_malformed_built: $yn, valid_same: $s, x_pass: ($xv and $xb and $s),
              x_malformed_sent: $xs, y_malformed_sent: $ys}}')"
echo "[wallet-requests] === WALLET-REQUESTS: $rig_verdict ==="
