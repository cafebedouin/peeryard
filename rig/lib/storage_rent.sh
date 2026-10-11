# rig/lib/storage_rent.sh: storage rent (demurrage) helpers: create holder boxes, age them, collect them, read claims.
# Sourced by rig.sh; scenario hooks may rely on hook_api.sh functions. See docs/storage-rent.md.
#
# Storage rent is permissionless: after the storage period (mainnet 4 * 365 * 720 = 1,051,200 blocks) anyone may spend
# an "expired" box with an EMPTY spending proof and context-extension variable #127 = the index of an output
# (ErgoInterpreter.verify / checkExpiredBox). Two branches: if the box value covers the storage fee
# (storageFeeFactor * box size in bytes), the named output must recreate the box (same script, tokens and registers
# R4-R9, creation height = the claiming block's height, value >= box value - fee); if it does not, the box may be
# consumed whole. The period is a compile-time constant, so a devnet test needs a node built with a short period
# (patches/test/) and PEERYARD_STORAGE_PERIOD set to it. Collecting rent is the mechanism's intended, honest use;
# these helpers build only claims the consensus rule accepts.
tree_of(){ rest "$1" "/script/addressToTree/$2" | jq -r '.tree // empty'; }   # ergoTree hex of an address
# fee_tree <node>: the node's fee-proposition ergoTree (the P2S miner-fee script), learned once from a real payment and
# cached. Needs a funded, matured miner wallet.
declare -A FEE_TREE
fee_tree(){ local n="$1" tx h id t
  [[ -n "${FEE_TREE[$n]:-}" ]] && { echo "${FEE_TREE[$n]}"; return; }
  tx="$(pay "$n" "$n" 100000000)"; [[ "$tx" =~ ^[0-9a-f]{64}$ ]] || { echo "" ; return 1; }
  for _ in $(seq 1 20); do mempool_ids "$n" | grep -q "$tx" || break; sleep 2; done; sleep 4
  for ((h=$(full_height "$n"); h > $(full_height "$n") - 25 && h > 0; h--)); do
    id="$(header_at "$n" "$h")"; [[ -n "$id" ]] || continue
    t="$(rest "$n" "/blocks/$id" | jq -r --arg tx "$tx" '.blockTransactions.transactions[]?|select(.id==$tx)|.outputs[].ergoTree' 2>/dev/null | grep -v '^0008cd' | head -1)"
    [[ -n "$t" ]] && { FEE_TREE[$n]="$t"; echo "$t"; return; }
  done; return 1; }
# storage_period <node>: the storage period in blocks the helpers assume. It is a compile-time constant in the node,
# not a reported parameter, so a short-period test build cannot announce it: set PEERYARD_STORAGE_PERIOD to the
# build's value (mainnet 1,051,200 otherwise).
storage_period(){ echo "${PEERYARD_STORAGE_PERIOD:-1051200}"; }
# storage_fee_factor <node>: nanoERG per byte of box per storage period, from /info's current parameters
storage_fee_factor(){ rest "$1" /info | jq -r '.parameters.storageFeeFactor // empty'; }
# rent_box <node> <value> [<owner address>] [<assets json>] [<registers json>]: create one box of <value> nanoERG owned
# by <owner address> (default the node's own address; pass a FOREIGN address to model a holder whose box the
# collecting wallet cannot spend), paid from <node>'s wallet. <assets json> is the wallet API's list
# ([{"tokenId":"..","amount":N}]), <registers json> its map ({"R4":"<serialized constant hex>"}). Waits for the
# payment to leave the mempool (polled every second, up to 80 s) and prints "boxId creationHeight", read from the
# confirmed transaction (so a foreign box, absent from the wallet's unspent set, is still found); prints nothing and
# returns 1 when the payment is refused or does not confirm.
rent_box(){ local n="$1" v="$2" a="${3:-}" assets="${4:-[]}" regs="${5:-}" req r tx t
  [[ -n "$a" ]] || a="$(address "$n")"
  t="$(tree_of "$n" "$a")"
  req="$(jq -cn --arg a "$a" --argjson v "$v" --argjson as "$assets" --arg rg "$regs" \
    '[{address:$a, value:$v, assets:$as} + (if $rg == "" then {} else {registers: ($rg | fromjson)} end)]')"
  r="$(wallet "$n" /wallet/payment/send "$req")"
  tx="$(jq -r 'if type=="string" then . else empty end' <<<"$r" 2>/dev/null)"
  [[ "$tx" =~ ^[0-9a-f]{64}$ ]] || { echo "[rent] rent_box refused: ${r:0:160}" >&2; return 1; }
  for _ in $(seq 1 80); do mempool_ids "$n" | grep -q "$tx" || break; sleep 1; done
  for _ in $(seq 1 10); do
    r="$(wallet "$n" "/wallet/transactionById?id=$tx" \
      | jq -r --argjson v "$v" --arg t "$t" '.outputs[]?|select(.value==$v and .ergoTree==$t)|"\(.boxId) \(.creationHeight)"' 2>/dev/null | head -1)"
    [[ -n "$r" ]] && { echo "$r"; return 0; }; sleep 1
  done; return 1; }
# rent_issue <node> <amount> <name>: issue a token to <node>'s own wallet address; prints the token id
rent_issue(){ local n="$1" amt="$2" name="$3" r tx
  r="$(wallet "$n" /wallet/assets/issue "$(jq -cn --argjson m "$amt" --arg nm "$name" '{amount:$m, name:$nm, description:"peeryard storage-rent test token", decimals:0}')")"
  tx="$(jq -r 'if type=="string" then . else empty end' <<<"$r" 2>/dev/null)"
  [[ "$tx" =~ ^[0-9a-f]{64}$ ]] || { echo "[rent] rent_issue refused: ${r:0:160}" >&2; return 1; }
  for _ in $(seq 1 80); do mempool_ids "$n" | grep -q "$tx" || break; sleep 1; done
  for _ in $(seq 1 10); do
    r="$(wallet "$n" "/wallet/transactionById?id=$tx" | jq -r '[.outputs[]?.assets[]?.tokenId][0] // empty' 2>/dev/null)"
    [[ -n "$r" ]] && { echo "$r"; return 0; }; sleep 1
  done; return 1; }
# rent_expired <node> <creationHeight>: 0 (true) if the box is old enough to collect at the current height
rent_expired(){ [[ $(( $(full_height "$1") - $2 )) -ge $(storage_period "$1") ]]; }
# rent_claim <node> <boxId> <boxValue> [<beneficiary tree>] [<fee nanoERG>]: build and submit a claim for an expired
# box whose value does not cover its storage fee (a "not covered" box, consumed whole; empty proof + var #127).
# fee defaults to the minimum 1,000,000; a higher fee models a collector bidding for inclusion. The beneficiary
# (default the node's own address) takes value - fee; the fee goes to the fee box. Prints the node's response (a tx
# id on acceptance, or its rejection text).
rent_claim(){ local n="$1" box="$2" val="$3" bt="${4:-}" fee="${5:-1000000}" ft h out body
  [[ -n "$bt" ]] || bt="$(tree_of "$n" "$(address "$n")")"
  ft="$(fee_tree "$n")"; [[ -n "$bt" && -n "$ft" ]] || { echo "no trees"; return 1; }
  h="$(full_height "$n")"; out=$(( val - fee ))
  body="$(jq -cn --arg b "$box" --arg bt "$bt" --arg ft "$ft" --argjson h "$h" --argjson o "$out" --argjson fee "$fee" \
    '{inputs:[{boxId:$b,spendingProof:{proofBytes:"",extension:{"127":"0300"}}}],dataInputs:[],
      outputs:[{value:$o,ergoTree:$bt,creationHeight:$h,assets:[],additionalRegisters:{}},
               {value:$fee,ergoTree:$ft,creationHeight:$h,assets:[],additionalRegisters:{}}]}')"
  ip netns exec "${NS[$n]}" curl -s --max-time 12 -X POST -H 'Content-Type: application/json' --data "$body" "http://127.0.0.1:${REST[$n]}/transactions" | tr -d '\n'; }

# rent_blocks <node> <h0> <h1> <file>: the full blocks at heights h0..h1 on <node>'s best chain, one JSON per line
# ({height, id, txs}) written to <file>; rent_audit reads them.
rent_blocks(){ local n="$1" h id; : > "$4"
  for ((h=$2; h<=$3; h++)); do id="$(header_at "$n" "$h")"; [[ -n "$id" ]] || continue
    rest "$n" "/blocks/$id" | jq -c --argjson h "$h" --arg id "$id" '{height:$h, id:$id, txs:.blockTransactions.transactions}' >> "$4"
  done; }
# jq definitions shared by rent_audit and box_size_check (the serialized size of a box from its JSON)
RENT_JQ_DEFS='
  def vlq: if . < 128 then 1 else 1 + ((. / 128 | floor) | vlq) end;
  def hexlen: length / 2;
  def hexbytes: [scan("..")] | map(. as $x | "0123456789abcdef" as $d | ($d | index($x[0:1])) * 16 + ($d | index($x[1:2])));
  def unvlq: reduce .[] as $b ({n: 0, s: 1, done: false};
               if .done then . else {n: (.n + ($b % 128) * .s), s: (.s * 128), done: ($b < 128)} end) | .n;
  def unzigzag: if . % 2 == 0 then . / 2 else -((. + 1) / 2) end;
  # var #127 is a serialized Short constant: type byte 03, then the value as a zigzag VLQ
  def short_const: if test("^03") then (.[2:] | hexbytes | unvlq | unzigzag) else null end;
  def regs: (.additionalRegisters // {}) | to_entries | map(select(.key | test("^R[4-9]$"))) | sort_by(.key)
            | map({key, value: (if (.value | type) == "object" then .value.serializedValue else .value end)});
  # ErgoBox bytes: value, ergoTree, creation height, token count, tokens (32-byte id + amount), register count,
  # registers, transaction id, output index
  def size: (.value | vlq) + (.ergoTree | hexlen) + (.creationHeight | vlq) + 1
            + ([.assets[]? | 32 + (.amount | vlq)] | add // 0) + 1 + ([regs[].value | hexlen] | add // 0)
            + 32 + (.index | vlq);
'
# rent_audit <blocks file> <storageFeeFactor> [<genesis boxes file>]: every storage-rent claim input in the blocks
# (empty proofBytes and extension key "127"), each checked against the consensus rule from the blocks alone: the spent
# box is looked up among the outputs of earlier blocks in the file (so the file must start at height 1) and the
# genesis boxes (a JSON array, as /utxo/genesis serves it), its size computed from its
# serialization (value, ergoTree, creation height, tokens, registers, transaction id, output index; VLQ fields), the
# fee is factor * size, and the output named by var #127 is checked when the fee is covered (same ergoTree, tokens and
# registers, creation height = the block's height, value >= box value - fee). One JSON line per claim, then a summary
# line {"summary":...}. A claim whose spent box is not in the file is reported with "box":"unknown".
rent_audit(){ local g="${3:-}"; [[ -n "$g" ]] || { g="$RIG_LOG_DIR/.no-genesis.json"; echo '[]' > "$g"; }
  jq -s -c --argjson f "$2" --argjson p "$(storage_period "")" --slurpfile g "$g" "$RENT_JQ_DEFS"'
  (reduce (($g[0][]), (.[] | .txs[] | .outputs[])) as $o ({}; .[$o.boxId] = $o)) as $boxes
  | [ .[] as $b | $b.txs[] as $tx | $tx.inputs[]
      | select(.spendingProof.proofBytes == "" and ((.spendingProof.extension // {}) | has("127")))
      | . as $in | $boxes[$in.boxId] as $box | ($in.spendingProof.extension["127"] | short_const) as $idx
      | if $box == null then {height: $b.height, block: $b.id, tx: $tx.id, input: $in.boxId, box: "unknown", var127: $idx, ok: false}
        else
          ($box | size) as $sz | ($f * $sz) as $fee | ($tx.outputs[$idx // 100000]) as $out
          | (if $box.value - $fee <= 0 then {branch: "consumed", ok: true}
             else {branch: "recreated", out_index: $idx, out_value: $out.value,
                   value_ok: ($out != null and $out.value >= $box.value - $fee),
                   tree_ok: ($out != null and $out.ergoTree == $box.ergoTree),
                   tokens_ok: ($out != null and ($out.assets // []) == ($box.assets // [])),
                   registers_ok: ($out != null and ($out | regs) == ($box | regs)),
                   height_ok: ($out != null and $out.creationHeight == $b.height)}
               | .ok = (.value_ok and .tree_ok and .tokens_ok and .registers_ok and .height_ok) end)
          + {height: $b.height, block: $b.id, tx: $tx.id, input: $in.boxId, box_value: $box.value,
             box_height: $box.creationHeight, age: ($b.height - $box.creationHeight), size: $sz, fee: $fee,
             tokens: ($box.assets // [] | length), registers: ($box | regs | length)}
        end ] as $claims
  | ($claims[]),
    {summary: {claim_inputs: ($claims | length), claim_txs: ([$claims[].tx] | unique | length),
               claim_blocks: ([$claims[].height] | unique | length),
               recreated: ([$claims[] | select(.branch == "recreated")] | length),
               consumed: ([$claims[] | select(.branch == "consumed")] | length),
               unknown: ([$claims[] | select(.box == "unknown")] | length),
               failed: ([$claims[] | select(.ok | not)] | length),
               younger_than_period: ([$claims[] | select(.age != null and .age < $p)] | length)}}' "$1"; }
# box_size_check <node> <boxId>: the box's size computed as rent_audit computes it, against the node's own
# serialization (/utxo/byIdBinary); prints "computed actual". A self-test of rent_audit's size formula.
box_size_check(){ local j b; j="$(rest "$1" "/utxo/byId/$2")"; b="$(rest "$1" "/utxo/byIdBinary/$2" | jq -r '.bytes // empty')"
  [[ -n "$j" && -n "$b" ]] || return 1
  echo "$(jq -r "$RENT_JQ_DEFS size" <<< "$j") $(( ${#b} / 2 ))"; }

# ---- competing collectors (the "mempool war"): tunable bots ----
# A "holder" is any owner of aging boxes (rent_box <node> <value> <owner>); a "collector" is a bot racing to claim
# expired boxes. rent_bot models one collector as a background loop. Modeling several honest collectors is the
# mechanism's normal contended state.
declare -A RENT_BOT_PID
# rent_bot <label> <node> <boxfile> [latency_ms=0] [fee_bid=0] [poll_ms=500]: background loop. boxfile lines are
# "boxId creationHeight value". For each expired, not-yet-won box the bot waits latency_ms, then submits a claim to
# <node> with fee = min + fee_bid. A win is marked in $RIG_LOG_DIR/rent_won/<boxId> (best-effort, so bots still
# collide as on a real network). Outcomes -> $RIG_LOG_DIR/bot_<label>.jsonl {t,box,result}. Stops on $RIG_LOG_DIR/rent_stop.
# RENT_BOT_STRATEGY: race (default; skip a box anyone has won) or compete (each bot submits every box once).
rent_bot(){ local label="$1" node="$2" bf="$3" lat="${4:-0}" bid="${5:-0}" poll="${6:-500}"
  local won="$RIG_LOG_DIR/rent_won" out="$RIG_LOG_DIR/bot_${label}.jsonl" bt; mkdir -p "$won"
  bt="$(tree_of "$node" "$(address "$node")")"   # this bot collects to <node>'s address
  local strat="${RENT_BOT_STRATEGY:-race}"; local tried="$RIG_LOG_DIR/tried_${label}"; mkdir -p "$tried"
  ( while [[ ! -e "$RIG_LOG_DIR/rent_stop" ]]; do
      while read -r box ch val; do
        [[ -n "$box" ]] || continue
        # race: skip a box already won by anyone (cooperative). compete: submit each box once regardless (contend).
        if [[ "$strat" == race ]]; then [[ -e "$won/$box" ]] && continue; else [[ -e "$tried/$box" ]] && continue; fi
        rent_expired "$node" "$ch" || continue
        [[ "$lat" -gt 0 ]] && sleep "$(awk -v m="$lat" 'BEGIN{printf "%.3f", m/1000}')"
        [[ "$strat" == race && -e "$won/$box" ]] && continue
        : > "$tried/$box"
        local r; r="$(rent_claim "$node" "$box" "$val" "$bt" $((1000000 + bid)))"
        if [[ "$r" =~ ^\"[0-9a-f]{64}\"$ ]]; then : > "$won/$box"; printf '{"t":%s,"box":"%s","result":"accepted","tx":%s}\n' "$(date +%s%3N)" "$box" "$r" >> "$out"
        else printf '{"t":%s,"box":"%s","result":"rejected","detail":%s}\n' "$(date +%s%3N)" "$box" "$(jq -Rc . <<<"${r:0:120}")" >> "$out"; fi
      done < "$bf"
      sleep "$(awk -v m="$poll" 'BEGIN{printf "%.3f", m/1000}')"
    done ) &
  RENT_BOT_PID[$label]=$!; echo "[rent] bot $label -> $node latency ${lat}ms bid $bid (pid ${RENT_BOT_PID[$label]})"; }
# rent_bots_stop: stop all collector bots
rent_bots_stop(){ : > "$RIG_LOG_DIR/rent_stop"; local l; for l in "${!RENT_BOT_PID[@]}"; do
    kill "${RENT_BOT_PID[$l]}" 2>/dev/null; wait "${RENT_BOT_PID[$l]}" 2>/dev/null; done; echo "[rent] bots stopped"; }
