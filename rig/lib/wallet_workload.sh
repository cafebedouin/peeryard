# shellcheck shell=bash
# wallet_workload.sh: a scripted wallet workload with invariant checks (rig/WALLET-WORKLOAD.md). Sourced by a rig hook
# (rig/examples/wallet-workload.sh) after rig.sh has defined its helpers (rest, wallet, address, full_height, ...).
#
# Roles (node names, from the environment; the shipped topologies use M, A, B):
#   WW_MINER (M)   mines and funds; payments go to its address; its chain is the reference for "confirmed"
#   WW_WALLET (A)  the wallet under test: every single-wallet step runs here
#   WW_TWIN (B)    the same mnemonic and derivation as A (one wallet restored on two nodes); used by the resubmit and
#                  conflict steps, which also check that every node ends on one chain and one state root
# The driver only collects: each step writes one observation JSON and rig/lib/wallet_check.jq judges it, so the
# no-node self-test (tests/wallet_workload.sh) runs the same judgement as a node run.
# Honest behaviour only: every call is a standard REST or wallet call a node operator can make.

WW_MINER="${WW_MINER:-M}"; WW_WALLET="${WW_WALLET:-A}"; WW_TWIN="${WW_TWIN:-B}"
WW_FEE="${WW_FEE:-1000000}"                       # nanoERG, the node's default wallet fee
WW_CONFIRM_S="${WW_CONFIRM_S:-150}"               # how long an accepted transaction may take to appear on the miner's chain
WW_CLEAR_S="${WW_CLEAR_S:-60}"                    # how long, after confirmation, a pool may keep the transaction or its rival
WW_SYNC_S="${WW_SYNC_S:-240}"                     # how long a follower may take to reach the miner's tip before a step
WW_AGREE_S="${WW_AGREE_S:-90}"                    # how long to look for all nodes at one height with one state root
WW_FUND_BOXES="${WW_FUND_BOXES:-12}"; WW_FUND_NANOERG="${WW_FUND_NANOERG:-5000000000}"
WW_CONTROL="${WW_CONTROL:-none}"                  # none | positive (the burn step also asserts the burned amount is still held: must FAIL)
WW_CHECK_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WW_DIR=""; WW_STEP=0; WW_TOKEN=""; WW_SCAN_BOXES="[]"; WW_MINER_ADDR=""; WW_ADDR=""

# the step lists the presets name (rig/WALLET-WORKLOAD.md, "Steps"); WW_STEPS or the topology's workload.steps override
ww_preset_steps(){ case "${1:-full}" in
  full)   echo "scan send-par:6 send:3 mint:1000 transfer:100 burn:50 fee:6 resubmit:0 resubmit:2 resubmit:8 conflict*3" ;;
  aa)     echo "send:3 mint:1000 transfer:100 burn:50 fee:6" ;;
  posctl) echo "mint:1000 burn:50" ;;
  conflict) echo "resubmit:0*3 conflict*3" ;;
  *) return 1 ;; esac; }
# ww_expand "<a b*3 c:2>": one step per line, the repeat expanded
ww_expand(){ local t k n i; for t in ${1//,/ }; do k="${t%%\**}"; n=1; [[ "$t" == *\** ]] && n="${t##*\*}"
  [[ "$n" =~ ^[0-9]+$ ]] || { echo "BAD:$t"; continue; }; for ((i = 0; i < n; i++)); do echo "$k"; done; done; }

ww_say(){ echo "[ww] $*"; }
ww_reply(){ jq -r 'if type == "string" then "ID " + . else "NO " + ((.detail // .reason // tojson) | gsub("\n"; " ") | .[0:400]) end' 2>/dev/null <<< "$1" || echo "NO unreadable reply: ${1:0:200}"; }
ww_info(){ rest "$1" /info; }
ww_heights(){ local n o='{}'; for n in "$@"; do o=$(jq -c --arg n "$n" --argjson h "$(full_height "$n" 2>/dev/null || echo 0)" '.[$n] = $h' <<< "$o"); done; echo "$o"; }
ww_tree(){ rest "$WW_WALLET" "/script/addressToTree/$1" | jq -r '.tree // empty'; }
ww_balance(){ wallet "$1" /wallet/balances | jq -c '{height: (.height // 0), erg: (.balance // 0), tokens: (.assets // {})}'; }
ww_pool_body(){ rest "$1" "/transactions/unconfirmed/byTransactionId/$2" | jq -c 'select(.id != null)' 2>/dev/null; }
ww_boxes(){ wallet "$1" /utxo/withPool/byIds "$2" 2>/dev/null; }   # POST; the api key header is harmless here

# blocks are cached by header id, so a reorg never leaves a stale height in the cache
ww_block(){ local n="$1" id="$2" f="$WW_DIR/blk/$2.json"
  [[ -s "$f" ]] || rest "$n" "/blocks/$id/transactions" \
    | jq -c '[.transactions[]? | {id, inputs: [.inputs[].boxId], outputs: [.outputs[] | {boxId, value, ergoTree, assets}]}]' > "$f.tmp" 2>/dev/null \
    && [[ -s "$f.tmp" ]] && mv "$f.tmp" "$f"
  cat "$f" 2>/dev/null || echo '[]'; }
# ww_chain_txs <node> <h0>: {h, id, inputs, outputs} per line for the node's current chain from h0 to its full height
ww_chain_txs(){ local n="$1" h0="$2" h1 h id; h1=$(full_height "$n" 2>/dev/null || echo 0)
  for ((h = h0; h <= h1; h++)); do id=$(header_at "$n" "$h"); [[ -n "$id" ]] || continue
    ww_block "$n" "$id" | jq -c --argjson h "$h" '.[] | . + {h: $h}'; done; }
# ww_where <node> <h0> <ids json>: {id: [heights]} on that node's chain
ww_where(){ ww_chain_txs "$1" "$2" | jq -sc --argjson ids "$3" '(reduce $ids[] as $i ({}; .[$i] = [])) as $z | reduce (.[] | select(.id as $x | $ids | index($x))) as $t ($z; .[$t.id] += [$t.h])'; }
# ww_wait_confirm <h0> <ids json>: wait until every id is on the miner's chain; prints {id: height|null}
ww_wait_confirm(){ local h0="$1" ids="$2" end=$((SECONDS + WW_CONFIRM_S)) w
  while :; do w=$(ww_where "$WW_MINER" "$h0" "$ids")
    jq -e 'all(.[]; length > 0)' <<< "$w" >/dev/null && break; [[ $SECONDS -ge $end ]] && break; sleep 3; done
  jq -c 'map_values(.[0] // null)' <<< "$w"; }
# ww_sync <nodes...>: each node has fully applied the miner's chain up to where the miner was when the call began
# (a follower trails a moving tip by a few blocks on this rig, so "at the tip" would be a race, not a check)
ww_sync(){ local end=$((SECONDS + WW_SYNC_S)) n ok hm i
  hm=$(full_height "$WW_MINER" 2>/dev/null || echo 0)
  while :; do ok=1
    for n in "$@"; do i=$(ww_info "$n"); jq -e --argjson m "$hm" '.fullHeight != null and .fullHeight >= $m' <<< "$i" >/dev/null 2>&1 || ok=0; done
    [[ $ok == 1 ]] && return 0; [[ $SECONDS -ge $end ]] && return 1; sleep 2; done; }
# ww_wallet_at <node> <height>: the node's wallet has processed that height
ww_wallet_at(){ local end=$((SECONDS + 60)); while [[ $SECONDS -lt $end ]]; do [[ "$(ww_balance "$1" | jq -r .height)" -ge "$2" ]] 2>/dev/null && return 0; sleep 2; done; return 1; }
# ww_quiet: every node's pool empty (a step starts from no pending transaction), at most 120 s
ww_quiet(){ local end=$((SECONDS + 120)) n s; while :; do s=0; for n in "${NODES[@]}"; do s=$((s + $(mempool_size "$n" 2>/dev/null || echo 0))); done
  [[ $s == 0 ]] && return 0; [[ $SECONDS -ge $end ]] && { ww_say "pools not empty after 120 s ($s pooled)"; return 1; }; sleep 2; done; }
# ww_pools_clear <ids json> <s>: wait until no node pools any of the ids; prints {pools_end, clear_s}
ww_pools_clear(){ local ids="$1" end=$((SECONDS + $2)) t0=$SECONDS n pools cs='{}'
  while :; do pools='{}'
    for n in "${NODES[@]}"; do pools=$(jq -c --arg n "$n" --argjson p "$(mempool_ids "$n" | jq -R . | jq -sc --argjson ids "$ids" 'map(select(. as $x | $ids | index($x)))')" '.[$n] = $p' <<< "$pools")
      jq -e --arg n "$n" '.[$n] != null' <<< "$cs" >/dev/null || { jq -e --arg n "$n" '.[$n] | length == 0' <<< "$pools" >/dev/null && cs=$(jq -c --arg n "$n" --argjson s $((SECONDS - t0)) '.[$n] = $s' <<< "$cs"); }; done
    jq -e 'all(.[]; length == 0)' <<< "$pools" >/dev/null && break; [[ $SECONDS -ge $end ]] && break; sleep 2; done
  jq -nc --argjson p "$pools" --argjson c "$cs" '{pools_end: $p, clear_s: $c}'; }
# ww_agree: every node's state root equals the root the miner's chain has at that node's own full height (its best
# full block is the miner's header there, and /info stateRoot is that header's stateRoot). A follower that trails the
# moving tip still agrees; a node on another chain, or with another root at the same block, does not. Prints
# "SAME@<miner h>:<root16> (A@h B@h)" or "DIFF@h:<node>=<what>"; re-read for up to WW_AGREE_S when a read races a block.
ww_agree(){ local end=$((SECONDS + WW_AGREE_S)) n i h id r mid mr hm out bad
  while :; do bad=""; out=""; hm=""
    for n in "${NODES[@]}"; do i=$(ww_info "$n"); h=$(jq -r '.fullHeight // 0' <<< "$i"); id=$(jq -r '.bestFullHeaderId // ""' <<< "$i"); r=$(jq -r '.stateRoot // ""' <<< "$i")
      mid=$(header_at "$WW_MINER" "$h"); mr=$([[ -n "$mid" ]] && rest "$WW_MINER" "/blocks/$mid/header" | jq -r '.stateRoot // ""')
      [[ "$n" == "$WW_MINER" ]] && hm="$h:${r:0:16}"
      if [[ -z "$id" || "$id" != "$mid" ]]; then bad="DIFF@$h:$n=not-on-miner-chain(${id:0:8}/${mid:0:8})"
      elif [[ -z "$r" || "$r" != "$mr" ]]; then bad="DIFF@$h:$n=root ${r:0:16} miner ${mr:0:16}"
      else out+=" $n@$h"; fi; done
    [[ -z "$bad" ]] && { echo "SAME@$hm (each node's root = the miner's at its height:$out)"; return 0; }
    [[ $SECONDS -ge $end ]] && { echo "$bad"; return 0; }; sleep 2; done; }

# ww_record <obs json>: judge one observation, print its lines, keep both
ww_record(){ local obs="$1" j f; f="$WW_DIR/obs_$(printf %02d "$WW_STEP").json"
  jq -c --argjson s "$WW_STEP" --arg c "$WW_CONTROL" '. + {step: $s, control: $c} | .setup //= null' <<< "$obs" > "$f"
  j=$(jq -c -L "$WW_CHECK_LIB" 'include "wallet_check"; judge' "$f") || j=$(jq -nc --argjson s "$WW_STEP" '{step: $s, kind: "?", verdict: "INCONCLUSIVE", setup: "observation unreadable", invariants: [], info: {}}')
  echo "$j" >> "$WW_DIR/steps.jsonl"
  jq -r '"[ww] step \(.step) \(.kind)\(if .arg then ":" + .arg else "" end): \(.verdict)\(if .setup then " (" + .setup + ")" else "" end)",
         (.invariants[] | "[ww]     \(if .ok then "ok  " else "FAIL" end) \(.name): \(.value)"),
         (if (.info | length) > 0 then "[ww]     info \(.info | tojson)" else empty end)' <<< "$j"; }

ww_generate(){ wallet "$1" /wallet/transaction/generate "$2"; }
ww_submit(){ wallet "$1" /transactions "$2"; }
# token sums and ERG total of the boxes a transaction spends (looked up with the pool, so a pooled parent's output counts)
ww_input_view(){ local b; b=$(ww_boxes "$1" "$(jq -c '[.inputs[].boxId]' <<< "$2")")
  jq -c '{in_tokens: (reduce (.[]?.assets[]?) as $a ({}; .[$a.tokenId] += $a.amount)), in_erg: ([.[]?.value] | add // 0), n: length}' <<< "${b:-[]}"; }
ww_out_view(){ jq -c '{out_tokens: (reduce (.outputs[]?.assets[]?) as $a ({}; .[$a.tokenId] += $a.amount)), out_erg: ([.outputs[]?.value] | add // 0)}' <<< "$1"; }

# ---- steps ------------------------------------------------------------------------------------------------------
# send / send-par <n>: n payments from the wallet to the miner (distinct amounts), one at a time or all at once
ww_step_send(){ local kind="$1" n="${2:-3}" h0 i pids=() f reply ids txs='{}' id b conf reqs
  ww_quiet; h0=$(full_height "$WW_MINER")
  for ((i = 1; i <= n; i++)); do f="$WW_DIR/send_${WW_STEP}_$i.txt"
    if [[ "$kind" == send-par ]]; then ( wallet "$WW_WALLET" /wallet/payment/send "[{\"address\":\"$WW_MINER_ADDR\",\"value\":$((100000000 + WW_STEP * 1000 + i))}]" > "$f" ) & pids+=($!)
    else wallet "$WW_WALLET" /wallet/payment/send "[{\"address\":\"$WW_MINER_ADDR\",\"value\":$((100000000 + WW_STEP * 1000 + i))}]" > "$f"; sleep 0.5; fi
  done
  [[ ${#pids[@]} -gt 0 ]] && wait "${pids[@]}"   # by pid: a bare `wait` would also wait for the rig's own background sampler
  reqs=$(for ((i = 1; i <= n; i++)); do reply=$(ww_reply "$(cat "$WW_DIR/send_${WW_STEP}_$i.txt")")
    if [[ "$reply" == ID* ]]; then jq -nc --argjson i "$i" --arg id "${reply#ID }" '{i: $i, id: $id, reason: null}'
    else jq -nc --argjson i "$i" --arg r "${reply#NO }" '{i: $i, id: null, reason: $r}'; fi; done | jq -sc .)
  ids=$(jq -c '[.[] | select(.id != null) | .id] | unique' <<< "$reqs")
  for id in $(jq -r '.[]' <<< "$ids"); do b=$(ww_pool_body "$WW_WALLET" "$id"); [[ -n "$b" ]] && txs=$(jq -c --argjson b "$b" '.[$b.id] = {inputs: [$b.inputs[].boxId]}' <<< "$txs"); done
  conf=$(ww_wait_confirm "$h0" "$ids")
  # bodies of accepted transactions already mined before the pool was read come from the chain
  txs=$(ww_chain_txs "$WW_MINER" "$h0" | jq -sc --argjson t "$txs" --argjson ids "$ids" 'reduce (.[] | select(.id as $x | $ids | index($x))) as $x ($t; .[$x.id] //= {inputs: $x.inputs})')
  ww_record "$(jq -nc --arg k "$kind" --arg a "$n" --argjson r "$reqs" --argjson t "$txs" --argjson c "$conf" --argjson s "$WW_SCAN_BOXES" \
    '{kind: $k, arg: $a, requests: $r, txs: $t, confirmed: ($c | with_entries(select(.value != null))), scan_boxes: $s}')"; }

# scan: register a scan (walletInteraction off) on a script the wallet's key can spend but the wallet does not track,
# fund it (confirmed boxes, then one left unconfirmed), then send from the wallet: a payment it can afford, and one
# to itself it can afford only by spending the scan's unconfirmed box (a correct wallet refuses it)
ww_step_scan(){ local k="${1:-2}" h own_tree p2s ptree len vlq sid inter h0 pay1 pay2 conf b body scan unc sends='[]' bal_c bal_u expect extra probe r v to id inputs
  ww_quiet; own_tree=$(ww_tree "$WW_ADDR")
  p2s=$(wallet "$WW_WALLET" /script/p2sAddress "{\"source\":\"PK(\\\"$WW_ADDR\\\") && sigmaProp(HEIGHT > 0)\",\"treeVersion\":0}" | jq -r '.address // empty')
  ptree=$([[ -n "$p2s" ]] && ww_tree "$p2s")
  [[ -n "$ptree" ]] || { ww_record "$(jq -nc '{kind: "scan", setup: "could not compile the scan script (/script/p2sAddress)"}')"; return; }
  len=$(( ${#ptree} / 2 )); vlq=""; while :; do if (( len < 128 )); then vlq+=$(printf %02x "$len"); break; fi; vlq+=$(printf %02x $(( (len & 127) | 128 ))); len=$(( len >> 7 )); done
  sid=$(wallet "$WW_WALLET" /scan/register "{\"scanName\":\"ww-scan-$WW_STEP\",\"walletInteraction\":\"off\",\"removeOffchain\":true,\"trackingRule\":{\"predicate\":\"equals\",\"register\":\"R1\",\"value\":\"0e$vlq$ptree\"}}" | jq -r '.scanId // empty')
  inter=$(wallet "$WW_WALLET" /scan/listAll | jq -r --argjson s "${sid:-0}" '.[] | select(.scanId == $s) | .walletInteraction')
  ww_say "scan $sid on $p2s (walletInteraction $inter)"
  h0=$(full_height "$WW_MINER")
  pay1=$(ww_reply "$(wallet "$WW_WALLET" /wallet/payment/send "$(jq -nc --arg a "$p2s" --argjson k "$k" '[range($k) | {address: $a, value: 1000000000}]')")")
  conf='{}'; [[ "$pay1" == ID* ]] && conf=$(ww_wait_confirm "$h0" "[\"${pay1#ID }\"]")
  h=$(jq -r '[.[]] | .[0] // empty' <<< "$conf")
  ww_sync "$WW_WALLET" || ww_say "WARN $WW_WALLET not at the miner's tip"; [[ "$h" =~ ^[0-9]+$ ]] && ww_wallet_at "$WW_WALLET" "$h"
  bal_c=$(ww_balance "$WW_WALLET" | jq -r .erg)
  # one more scan box, left unconfirmed: everything below happens before the next block, or is recorded as not
  pay2=$(ww_reply "$(wallet "$WW_WALLET" /wallet/payment/send "[{\"address\":\"$p2s\",\"value\":2000000000}]")")
  body='{"inputs":[],"outputs":[]}'; [[ "$pay2" == ID* ]] && body=$(ww_pool_body "$WW_WALLET" "${pay2#ID }"); [[ -n "$body" ]] || body='{"inputs":[],"outputs":[]}'
  bal_u=$(wallet "$WW_WALLET" /wallet/balances/withUnconfirmed | jq -r '.balance // 0')
  # what the wallet's own boxes are worth with that payment pending: confirmed - spent inputs + own change
  expect=$(jq -r --argjson c "$bal_c" --arg t "$own_tree" --argjson v "$(ww_input_view "$WW_WALLET" "$body" | jq .in_erg)" \
    '$c - $v + ([.outputs[]? | select(.ergoTree == $t) | .value] | add // 0)' <<< "$body")
  extra=$((bal_u - expect))
  # the probe: the wallet's own spendable value plus half the unconfirmed scan box (affordable only by spending it)
  probe=$((expect - WW_FEE + 1000000000))
  # the probe pays the wallet's own address, so a wallet that does spend the scan box keeps its funds for later steps
  for r in "probe $probe $WW_ADDR" "pay 100000000 $WW_MINER_ADDR"; do
    read -r r v to <<< "$r"
    b=$(wallet "$WW_WALLET" /wallet/payment/send "[{\"address\":\"$to\",\"value\":$v}]")
    id=$(ww_reply "$b"); inputs='[]'
    if [[ "$id" == ID* ]]; then inputs=$(ww_pool_body "$WW_WALLET" "${id#ID }" | jq -c '[.inputs[].boxId]'); fi
    sends=$(jq -c --arg l "$r" --arg rep "$id" --argjson in "${inputs:-[]}" '. + [{label: $l, id: (if $rep | startswith("ID ") then $rep[3:] else null end), reason: (if $rep | startswith("NO ") then $rep[3:] else null end), inputs: $in}]' <<< "$sends")
  done
  unc=$(jq -c --arg t "$ptree" '[.outputs[]? | select(.ergoTree == $t) | .boxId]' <<< "$body")
  scan=$(wallet "$WW_WALLET" "/scan/unspentBoxes/${sid:-0}?minConfirmations=-1&limit=2500" | jq -c --argjson u "$unc" '([.[]?.box.boxId] + $u) | unique')
  ww_say "scan boxes $(jq length <<< "$scan") ($(jq length <<< "$unc") unconfirmed); wallet balance confirmed $bal_c, with unconfirmed $bal_u, own boxes worth $expect"
  WW_SCAN_BOXES="$scan"
  ww_record "$(jq -nc --arg i "${inter:-}" --argjson s "$scan" --argjson u "$unc" --argjson se "$sends" --argjson k "$((k + 1))" --argjson x "$extra" --arg a "$k" \
    '{kind: "scan", arg: $a, interaction: $i, scan_boxes: $s, unconfirmed_scan_boxes: $u, sends: $se, expected_boxes: $k,
      balance_includes_scan: ($x > 0), unconfirmed_balance_minus_own: $x}')"
  ww_quiet || true; }

# mint <amount>: an asset issue through the wallet's transaction builder (generate, then submit)
ww_step_mint(){ local amt="${1:-1000}" h0 tx iv sub conf h bal txs
  ww_quiet; h0=$(full_height "$WW_MINER")
  tx=$(ww_generate "$WW_WALLET" "{\"requests\":[{\"address\":\"$WW_ADDR\",\"ergValue\":1000000,\"amount\":$amt,\"name\":\"WW$WW_STEP\",\"description\":\"wallet workload\",\"decimals\":0}],\"fee\":$WW_FEE}")
  if ! jq -e '.id' <<< "$tx" >/dev/null 2>&1; then ww_record "$(jq -nc --arg r "$(ww_reply "$tx")" '{kind: "mint", tx: null, reason: $r}')"; return; fi
  iv=$(ww_input_view "$WW_WALLET" "$tx"); sub=$(ww_reply "$(ww_submit "$WW_WALLET" "$tx")")
  conf=$(ww_wait_confirm "$h0" "[$(jq -c .id <<< "$tx")]"); h=$(jq -r '.[]' <<< "$conf")
  ww_sync "$WW_WALLET" || true; [[ "$h" =~ ^[0-9]+$ ]] && ww_wallet_at "$WW_WALLET" "$h"
  bal=$(ww_balance "$WW_WALLET"); txs=$(jq -c '{(.id): {inputs: [.inputs[].boxId]}}' <<< "$tx")
  ww_record "$(jq -nc --arg a "$amt" --argjson tx "$tx" --argjson iv "$iv" --arg sub "$sub" --arg h "$h" --argjson b "$bal" --argjson t "$txs" --argjson s "$WW_SCAN_BOXES" \
    '{kind: "mint", arg: $a, request: {amount: ($a | tonumber)}, tx: {id: $tx.id, inputs: [$tx.inputs[].boxId], outputs: [$tx.outputs[] | {assets}]},
      input_tokens: $iv.in_tokens, submitted: (if $sub | startswith("ID ") then $sub[3:] else null end), reason: (if $sub | startswith("NO ") then $sub[3:] else null end),
      confirmed: ($h | tonumber? // null), wallet_after: $b.tokens, txs: $t, scan_boxes: $s}')"
  WW_TOKEN=$(jq -r '.info.token // empty' < <(tail -1 "$WW_DIR/steps.jsonl")); }

# transfer <amount> / burn <amount>: of the token the last mint made
ww_step_token(){ local kind="$1" amt="${2:-100}" h0 tx iv ov sub conf h sb sa rb ra req txs
  [[ -n "$WW_TOKEN" ]] || { ww_record "$(jq -nc --arg k "$kind" --arg a "$amt" '{kind: $k, arg: $a, token: null}')"; return; }
  ww_quiet; h0=$(full_height "$WW_MINER")
  sb=$(ww_balance "$WW_WALLET"); rb=$(ww_balance "$WW_MINER")
  if [[ "$kind" == transfer ]]; then req="{\"requests\":[{\"address\":\"$WW_MINER_ADDR\",\"value\":1000000,\"assets\":[{\"tokenId\":\"$WW_TOKEN\",\"amount\":$amt}]}],\"fee\":$WW_FEE}"
  else req="{\"requests\":[{\"assetsToBurn\":[{\"tokenId\":\"$WW_TOKEN\",\"amount\":$amt}]}],\"fee\":$WW_FEE}"; fi
  tx=$(ww_generate "$WW_WALLET" "$req")
  if ! jq -e '.id' <<< "$tx" >/dev/null 2>&1; then ww_record "$(jq -nc --arg k "$kind" --arg a "$amt" --arg t "$WW_TOKEN" --arg r "$(ww_reply "$tx")" '{kind: $k, arg: $a, token: $t, tx: null, reason: $r}')"; return; fi
  iv=$(ww_input_view "$WW_WALLET" "$tx"); ov=$(ww_out_view "$tx"); sub=$(ww_reply "$(ww_submit "$WW_WALLET" "$tx")")
  conf=$(ww_wait_confirm "$h0" "[$(jq -c .id <<< "$tx")]"); h=$(jq -r '.[]' <<< "$conf")
  ww_sync "$WW_WALLET" || true
  if [[ "$h" =~ ^[0-9]+$ ]]; then ww_wallet_at "$WW_WALLET" "$h"; ww_wallet_at "$WW_MINER" "$h"; fi
  sa=$(ww_balance "$WW_WALLET"); ra=$(ww_balance "$WW_MINER"); txs=$(jq -c '{(.id): {inputs: [.inputs[].boxId]}}' <<< "$tx")
  ww_record "$(jq -nc --arg k "$kind" --arg a "$amt" --arg t "$WW_TOKEN" --argjson tx "$tx" --argjson iv "$iv" --argjson ov "$ov" --arg sub "$sub" --arg h "$h" \
      --argjson sb "$sb" --argjson sa "$sa" --argjson rb "$rb" --argjson ra "$ra" --argjson f "$WW_FEE" --argjson x "$txs" --argjson s "$WW_SCAN_BOXES" \
    '{kind: $k, arg: $a, token: $t, amount: ($a | tonumber), fee: $f, tx: {id: $tx.id}, txs: $x, scan_boxes: $s,
      submitted: (if $sub | startswith("ID ") then $sub[3:] else null end), reason: (if $sub | startswith("NO ") then $sub[3:] else null end),
      tx_in_tokens: $iv.in_tokens, tx_out_tokens: $ov.out_tokens, tx_in_erg: $iv.in_erg, tx_out_erg: $ov.out_erg, confirmed: ($h | tonumber? // null),
      sender_before: ($sb.tokens[$t] // 0), sender_after: ($sa.tokens[$t] // 0), receiver_before: ($rb.tokens[$t] // 0), receiver_after: ($ra.tokens[$t] // 0),
      wallet_before: {erg: $sb.erg, tokens: $sb.tokens}, wallet_after: {erg: $sa.erg, tokens: $sa.tokens}}')"; }

# fee <n>: n payments with rising fees put a load in the pool, then the fee endpoints are read at once
ww_step_fee(){ local n="${1:-6}" i h0 ids='[]' r gf='[]' wt='[]' w fee v hist ps
  ww_quiet; h0=$(full_height "$WW_MINER")
  for ((i = 1; i <= n; i++)); do r=$(ww_reply "$(wallet "$WW_WALLET" /wallet/transaction/send "{\"requests\":[{\"address\":\"$WW_MINER_ADDR\",\"value\":$((10000000 + i))}],\"fee\":$((WW_FEE * i))}")")
    [[ "$r" == ID* ]] && ids=$(jq -c --arg i "${r#ID }" '. + [$i]' <<< "$ids"); sleep 0.3; done
  ps=$(mempool_size "$WW_WALLET")
  for w in 1 2 5 10 30; do v=$(rest "$WW_WALLET" "/transactions/getFee?waitTime=$w&txSize=200"); gf=$(jq -c --argjson w "$w" --arg v "$v" '. + [{wait: $w, size: 200, fee: ($v | tonumber? // null)}]' <<< "$gf"); done
  for fee in 1000000 2000000 5000000 10000000 100000000; do v=$(rest "$WW_WALLET" "/transactions/waitTime?fee=$fee&txSize=200"); wt=$(jq -c --argjson f "$fee" --arg v "$v" '. + [{fee: $f, size: 200, ms: ($v | tonumber? // null)}]' <<< "$wt"); done
  hist=$(rest "$WW_WALLET" "/transactions/poolHistogram?bins=10&maxtime=60000" | jq -c 'if type == "array" then . else null end' 2>/dev/null)
  ww_wait_confirm "$h0" "$ids" >/dev/null
  ww_record "$(jq -nc --arg a "$n" --argjson g "$gf" --argjson w "$wt" --argjson h "${hist:-null}" --argjson p "${ps:-0}" \
    '{kind: "fee", arg: $a, getFee: $g, waitTime: $w, hist: $h, pool_size: $p}')"; }

# resubmit <lag s>: one signed transaction submitted to the wallet's node, then the same bytes to the twin after the lag
ww_step_resubmit(){ local lag="${1:-0}" st h0 tx id r1 r2 conf pc et
  ww_quiet; ww_sync "${NODES[@]}" || ww_say "WARN not every node at the miner's tip before the step"
  st=$(ww_heights "${NODES[@]}"); h0=$(full_height "$WW_MINER")
  tx=$(ww_generate "$WW_WALLET" "{\"requests\":[{\"address\":\"$WW_MINER_ADDR\",\"value\":$((100000000 + WW_STEP))}],\"fee\":$WW_FEE}")
  id=$(jq -r '.id // empty' <<< "$tx" 2>/dev/null)
  [[ -n "$id" ]] || { ww_record "$(jq -nc --arg a "$lag" --arg r "$(ww_reply "$tx")" '{kind: "resubmit", arg: $a, id: null, reason: $r}')"; return; }
  r1=$(ww_reply "$(ww_submit "$WW_WALLET" "$tx")"); sleep "$lag"; r2=$(ww_reply "$(ww_submit "$WW_TWIN" "$tx")")
  ww_say "resubmit lag ${lag}s: $WW_WALLET ${r1:0:20}, $WW_TWIN ${r2:0:90}"
  conf=$(ww_wait_confirm "$h0" "[\"$id\"]"); ww_sync "${NODES[@]}" || true
  pc=$(ww_pools_clear "[\"$id\"]" "$WW_CLEAR_S")
  ww_finish_multi "$(jq -nc --arg a "$lag" --arg id "$id" --arg r1 "$r1" --arg r2 "$r2" --arg w "$WW_WALLET" --arg t "$WW_TWIN" --argjson st "$st" --argjson pc "$pc" \
    '{kind: "resubmit", arg: $a, lag_s: ($a | tonumber), id: $id, start_heights: $st,
      submits: [[$w, $r1], [$t, $r2]] | map({node: .[0], reply_id: (if .[1] | startswith("ID ") then .[1][3:] else null end), reason: (if .[1] | startswith("NO ") then .[1][3:] else null end)})} + $pc')" "[\"$id\"]" "$h0"; }

# conflict: one box, two different transactions spending it, built by the wallet on two nodes holding the same
# mnemonic and submitted to the two nodes at the same moment
ww_step_conflict(){ local st h0 box raw t1 t2 i1 i2 p1 p2 r1 r2 ids pc
  ww_quiet; ww_sync "${NODES[@]}" || ww_say "WARN not every node at the miner's tip before the step"
  st=$(ww_heights "${NODES[@]}"); h0=$(full_height "$WW_MINER")
  box=$(wallet "$WW_WALLET" "/wallet/boxes/unspent?minConfirmations=2&limit=2500" | jq -r '[.[]? | select((.box.assets | length) == 0 and .box.value >= 400000000) | .box.boxId] | .[0] // empty')
  raw=$([[ -n "$box" ]] && rest "$WW_WALLET" "/utxo/byIdBinary/$box" | jq -r '.bytes // empty')
  [[ -n "$raw" && -n "$(rest "$WW_TWIN" "/utxo/byId/$box" | jq -r '.boxId // empty')" ]] || {
    ww_record "$(jq -nc --arg b "$box" '{kind: "conflict", ids: [], reason: "no confirmed box both nodes hold (\($b))"}')"; return; }
  t1=$(ww_generate "$WW_WALLET" "{\"requests\":[{\"address\":\"$WW_MINER_ADDR\",\"value\":$((100000000 + WW_STEP))}],\"inputsRaw\":[\"$raw\"],\"fee\":$WW_FEE}")
  t2=$(ww_generate "$WW_TWIN" "{\"requests\":[{\"address\":\"$WW_MINER_ADDR\",\"value\":$((200000000 + WW_STEP))}],\"inputsRaw\":[\"$raw\"],\"fee\":$WW_FEE}")
  i1=$(jq -r '.id // empty' <<< "$t1" 2>/dev/null); i2=$(jq -r '.id // empty' <<< "$t2" 2>/dev/null)
  [[ -n "$i1" && -n "$i2" ]] || { ww_record "$(jq -nc --arg r "$WW_WALLET: $(ww_reply "$t1" | cut -c1-150) / $WW_TWIN: $(ww_reply "$t2" | cut -c1-150)" '{kind: "conflict", ids: [], reason: $r}')"; return; }
  ( ww_submit "$WW_WALLET" "$t1" > "$WW_DIR/c1_$WW_STEP.txt" ) & p1=$!
  ( ww_submit "$WW_TWIN" "$t2" > "$WW_DIR/c2_$WW_STEP.txt" ) & p2=$!
  wait "$p1" "$p2"
  r1=$(ww_reply "$(cat "$WW_DIR/c1_$WW_STEP.txt")"); r2=$(ww_reply "$(cat "$WW_DIR/c2_$WW_STEP.txt")")
  ww_say "conflict on box ${box:0:16}: t1 ${i1:0:16} at $WW_WALLET -> ${r1:0:90}; t2 ${i2:0:16} at $WW_TWIN -> ${r2:0:90}"
  ids=$(jq -nc --arg a "$i1" --arg b "$i2" '[$a, $b]')
  # wait for either to confirm on the miner's chain, then for every node to follow and every pool to drop both
  local end=$((SECONDS + WW_CONFIRM_S)); while [[ $SECONDS -lt $end ]]; do ww_where "$WW_MINER" "$h0" "$ids" | jq -e 'any(.[]; length > 0)' >/dev/null && break; sleep 3; done
  ww_sync "${NODES[@]}" || true
  pc=$(ww_pools_clear "$ids" "$WW_CLEAR_S")
  ww_finish_multi "$(jq -nc --argjson ids "$ids" --arg b "$box" --arg r1 "$r1" --arg r2 "$r2" --arg w "$WW_WALLET" --arg t "$WW_TWIN" --argjson st "$st" --argjson pc "$pc" \
    '{kind: "conflict", ids: $ids, box: $b, start_heights: $st,
      submits: [[$w, $r1], [$t, $r2]] | map({node: .[0], reply_id: (if .[1] | startswith("ID ") then .[1][3:] else null end), reason: (if .[1] | startswith("NO ") then .[1][3:] else null end)})} + $pc')" "$ids" "$h0"; }

# the end of a multi-node step: every node's chain read for the ids, end heights, the state-root agreement
ww_finish_multi(){ local obs="$1" ids="$2" h0="$3" n chain='{}' ag et
  ag=$(ww_agree); et=$(ww_heights "${NODES[@]}")
  for n in "${NODES[@]}"; do chain=$(jq -c --arg n "$n" --argjson w "$(ww_where "$n" "$h0" "$ids")" '.[$n] = $w' <<< "$chain"); done
  # resubmit judges a single id: its chain entry is that id's height list
  ww_record "$(jq -c --argjson c "$chain" --argjson e "$et" --arg ag "$ag" --argjson ids "$ids" \
    '. + {end_heights: $e, agree: $ag, chain: (if .kind == "resubmit" then ($c | map_values(.[$ids[0]])) else $c end)}' <<< "$obs")"; }

# ---- the run --------------------------------------------------------------------------------------------------------
# ww_fund: the miner matures, pays the wallet WW_FUND_BOXES boxes, and both wallet nodes see them confirmed
ww_fund(){ local need=$((WW_FUND_BOXES * WW_FUND_NANOERG + 2000000000)) r h0 conf h
  r=$(wait_balance "$WW_MINER" "$need" 400) || { echo "miner balance $r < $need after 400 s"; return 1; }
  h0=$(full_height "$WW_MINER")
  r=$(ww_reply "$(wallet "$WW_MINER" /wallet/payment/send "$(jq -nc --arg a "$WW_ADDR" --argjson k "$WW_FUND_BOXES" --argjson v "$WW_FUND_NANOERG" '[range($k) | {address: $a, value: $v}]')")")
  [[ "$r" == ID* ]] || { echo "funding payment refused: ${r#NO }"; return 1; }
  conf=$(ww_wait_confirm "$h0" "[\"${r#ID }\"]"); h=$(jq -r '.[]' <<< "$conf")
  [[ "$h" =~ ^[0-9]+$ ]] || { echo "funding payment not confirmed in ${WW_CONFIRM_S} s"; return 1; }
  ww_sync "${NODES[@]}" || { echo "followers not at the miner's tip within ${WW_SYNC_S} s: $(ww_heights "${NODES[@]}")"; return 1; }
  ww_wallet_at "$WW_WALLET" "$h" && ww_wallet_at "$WW_TWIN" "$h" || { echo "wallets did not process height $h"; return 1; }
  ww_say "funded: $WW_FUND_BOXES x $WW_FUND_NANOERG nanoERG at height $h; $WW_WALLET $(ww_balance "$WW_WALLET" | jq -c '{erg}'), $WW_TWIN $(ww_balance "$WW_TWIN" | jq -c '{erg}')"; }

# ww_run <steps>: fund, run every step, print the verdict line and RESULT_JSON; sets rig_verdict
ww_run(){ local steps="$1" s k a r sum v line vers n unresp=0
  WW_DIR="${RIG_LOG_DIR:-$SCRATCH}/wallet-workload"; mkdir -p "$WW_DIR/blk"; : > "$WW_DIR/steps.jsonl"
  WW_ADDR=$(address "$WW_WALLET"); WW_MINER_ADDR=$(address "$WW_MINER")
  ww_say "roles: miner $WW_MINER ($WW_MINER_ADDR), wallet $WW_WALLET ($WW_ADDR), twin $WW_TWIN ($(address "$WW_TWIN")); control $WW_CONTROL"
  ww_say "steps: $steps"
  if [[ -z "$WW_ADDR" || "$WW_ADDR" != "$(address "$WW_TWIN")" || "$WW_ADDR" == "$WW_MINER_ADDR" ]]; then
    echo "[wallet-workload] INCONCLUSIVE: the wallet and its twin must share the first address and differ from the miner (check the testMnemonic overrides)"; rig_verdict=INCONCLUSIVE; return; fi
  if ! r=$(ww_fund); then echo "$r"; echo "[wallet-workload] INCONCLUSIVE: funding failed: $(tail -1 <<< "$r")"; rig_verdict=INCONCLUSIVE; return; fi
  echo "$r"
  while IFS= read -r s; do [[ -n "$s" ]] || continue; WW_STEP=$((WW_STEP + 1)); k="${s%%:*}"; a=""; [[ "$s" == *:* ]] && a="${s#*:}"
    ww_say "---- step $WW_STEP: $s (height $(full_height "$WW_MINER"))"
    case "$k" in
      send|send-par) ww_step_send "$k" "${a:-3}" ;;
      scan) ww_step_scan "${a:-2}" ;;
      mint) ww_step_mint "${a:-1000}" ;;
      transfer|burn) ww_step_token "$k" "${a:-100}" ;;
      fee) ww_step_fee "${a:-6}" ;;
      resubmit) ww_step_resubmit "${a:-0}" ;;
      conflict) ww_step_conflict ;;
      *) ww_record "$(jq -nc --arg k "$k" '{kind: $k}')" ;;
    esac
  done < <(ww_expand "$steps")
  for n in "${NODES[@]}"; do rest "$n" /info | jq -e '.appVersion' >/dev/null 2>&1 || unresp=$((unresp + 1)); done
  sum=$(jq -sc -L "$WW_CHECK_LIB" 'include "wallet_check"; summarize' "$WW_DIR/steps.jsonl")
  v=$(jq -r .verdict <<< "$sum")
  line="steps $(jq -r .steps <<< "$sum"): $(jq -r .pass <<< "$sum") pass, $(jq -r .fail <<< "$sum") fail, $(jq -r .inconclusive <<< "$sum") inconclusive; control $(jq -r .control <<< "$sum")"
  line+="; conflict two-in-flight $(jq -r '"\(.conflict_two_in_flight)/\(.conflict_runs)"' <<< "$sum"), resubmit both-accepted $(jq -r '"\(.resubmit_two_accepted)/\(.resubmit_runs)"' <<< "$sum")"
  echo "[wallet-workload] === WALLET-WORKLOAD: $v ($line) ==="
  case "$v" in PASS|CONTROL-TRIPPED) rig_verdict=PASS ;; INCONCLUSIVE) rig_verdict=INCONCLUSIVE ;; *) rig_verdict=FAIL ;; esac
  if [[ "$v" == INCONCLUSIVE ]]; then
    echo "[wallet-workload] INCONCLUSIVE: $(jq -r 'select(.verdict == "INCONCLUSIVE") | "step \(.step) \(.kind): \(.setup)"' "$WW_DIR/steps.jsonl" | head -3 | paste -sd ';')"; return; fi
  vers=$(for n in "${NODES[@]}"; do jq -nc --arg n "$n" --arg v "$(rest "$n" /info | jq -r '.appVersion // "unknown"')" '{($n): $v}'; done | jq -sc 'add')
  echo "RESULT_JSON $(jq -nc --argjson s "$sum" --argjson v "$vers" --argjson u "$unresp" --arg sc "${WW_SCENARIO:-wallet-workload}" '{schema_version: 1, scenario: $sc, versions: $v,
    metrics: {pass: $s.pass_all, control_tripped: $s.control_tripped, steps: $s.steps, steps_pass: $s.pass, steps_fail: $s.fail,
              conflict_runs: $s.conflict_runs, conflict_two_in_flight: $s.conflict_two_in_flight,
              resubmit_runs: $s.resubmit_runs, resubmit_two_accepted: $s.resubmit_two_accepted, unresponsive_after: $u}}')"; }
