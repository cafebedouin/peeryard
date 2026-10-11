# shellcheck shell=bash
# rig/lib/indexer.sh: read a JVM node's extra indexer (ergo.node.extraIndex = true) into one JSON snapshot, for
# rig/indexer-cmp.sh to compare. Sourced by a hook (rig/examples/indexer-diff.sh); needs the rig's NS/REST arrays.
#
#   idx_heights <node>                       one line: "<fullHeight> <headersHeight> <indexedHeight> <bestFullHeaderId>"
#   idx_snapshot_global <node> <dir>         the global part (every box and transaction by global index, the range
#                                            listings, tokens) and the settle record before; writes <dir>/global.json
#   idx_addresses <dir>                      the distinct addresses of the boxes in <dir>/global.json, one per line
#   idx_snapshot_finish <node> <dir> <addr file> <out.json>
#                                            the per-address part for every address in the file (one per line), the
#                                            settle record after, and the assembled snapshot in <out.json>
#
# Routes read (ergo's src/main/resources/api/openapi.yaml, tag "blockchain"; the same in v6.0.7 and the 6.0.8 candidate,
# which only adds a 503 answer while the indexer recovers):
#   /blockchain/indexedHeight                         global.indexedHeight (indexedHeight, fullHeight)
#   /blockchain/box/range?limit=1, /box/byId/<id>     the newest box's globalIndex, so the box count = that + 1
#   /blockchain/box/byIndex/<i>, i = 0 .. count-1     every indexed box, full object (address, value, assets, spent tx,
#                                                     spending/inclusion height, global index)
#   /blockchain/box/range?limit=<count>               the global box-id listing
#   /blockchain/transaction/range?limit=1, /transaction/byId/<id>, /transaction/byIndex/<i>, /transaction/range
#                                                     the same for transactions
#   /blockchain/token/byId/<id>                       every token id found in a box's assets
#   /blockchain/box/byTokenId/<id>, /box/unspent/byTokenId/<id>   box ids (+ total) per token
#   POST /blockchain/balance                          per address: the confirmed balance (the unconfirmed half is the
#                                                     node's mempool, not the index, and is left out)
#   POST /blockchain/transaction/byAddress            per address: transaction ids in the order served, and total
#   POST /blockchain/box/byAddress                    per address: box ids in the order served, and total
#   POST /blockchain/box/unspent/byAddress            per address: unspent boxes (boxId, value, assets, globalIndex,
#                                                     inclusionHeight), confirmed only (includeUnconfirmed=false)
# Ranges are never asked past the end: v6.0.7 answers an index beyond the last with 500 (None.get).
# A request that answers neither 200 nor 404 is listed in the snapshot's "errors" and makes the comparison
# INCONCLUSIVE (the settle rule, rig/indexer-cmp.sh); a 404 is an answer and is compared as {"status":404}.
IDX_PAGE=${IDX_PAGE:-2000}   # page size for the per-address listings (the node's cap is 16384)

# _idx_req <node> <dir> <path> [json body]: one GET (or POST with the body); prints the JSON answer on 200,
# {"status":404} on 404, else {"status":<code>} and appends {path, status} to <dir>/errors.jsonl
_idx_req(){ local n="$1" d="$2" p="$3" body="${4:-}" f code
  f="$(mktemp "$d/req.XXXXXX")"
  if [[ -n "$body" ]]; then
    code=$(ip netns exec "${NS[$n]}" curl -s -o "$f" -w '%{http_code}' --max-time 15 -X POST -H 'Content-Type: application/json' \
      --data "$body" "http://127.0.0.1:${REST[$n]}$p")
  else code=$(ip netns exec "${NS[$n]}" curl -s -o "$f" -w '%{http_code}' --max-time 15 "http://127.0.0.1:${REST[$n]}$p"); fi
  if [[ "$code" == 200 ]] && jq -c . "$f" 2>/dev/null; then :
  elif [[ "$code" == 404 ]]; then echo '{"status":404}'
  else jq -cn --arg p "$p" --arg c "$code" '{path: $p, status: ($c | tonumber? // $c)}' >> "$d/errors.jsonl"; jq -cn --arg c "$code" '{status: ($c | tonumber? // $c)}'; fi
  rm -f "$f"; }

idx_heights(){ local n="$1" info ih
  info="$(rest "$n" /info)"; ih="$(rest "$n" /blockchain/indexedHeight | jq -r '.indexedHeight // -1' 2>/dev/null)"
  printf '%s %s %s %s\n' "$(jq -r '.fullHeight // 0' <<< "$info" 2>/dev/null)" "$(jq -r '.headersHeight // 0' <<< "$info" 2>/dev/null)" \
    "${ih:--1}" "$(jq -r '.bestFullHeaderId // "none"' <<< "$info" 2>/dev/null)"; }
_idx_settle_rec(){ local f h ih id; read -r f h ih id <<< "$(idx_heights "$1")"
  jq -cn --arg f "$f" --arg ih "$ih" --arg id "$id" '{fullHeight: ($f | tonumber? // null), indexedHeight: ($ih | tonumber? // null), bestFullHeaderId: $id}'; }

# _idx_count <node> <dir> <box|transaction>: the number of indexed objects (newest one's globalIndex + 1), 0 if none
_idx_count(){ local n="$1" d="$2" k="$3" id g
  id="$(_idx_req "$n" "$d" "/blockchain/$k/range?limit=1" | jq -r 'if type == "array" then .[0] // empty else empty end')"
  [[ "$id" =~ ^[0-9a-f]{64}$ ]] || { echo 0; return; }
  g="$(_idx_req "$n" "$d" "/blockchain/$k/byId/$id" | jq -r '.globalIndex // empty')"
  [[ "$g" =~ ^[0-9]+$ ]] && echo $((g + 1)) || echo 0; }

idx_snapshot_global(){ local n="$1" d="$2" nb nt i t
  mkdir -p "$d"; : > "$d/errors.jsonl"; : > "$d/boxes.jsonl"; : > "$d/txs.jsonl"; : > "$d/tokens.jsonl"
  _idx_settle_rec "$n" > "$d/settle_before.json"
  _idx_req "$n" "$d" /blockchain/indexedHeight > "$d/indexed.json"
  nb=$(_idx_count "$n" "$d" box); nt=$(_idx_count "$n" "$d" transaction)
  for ((i = 0; i < nb; i++)); do _idx_req "$n" "$d" "/blockchain/box/byIndex/$i" | jq -c --argjson i "$i" '{key: ($i | tostring), value: .}' >> "$d/boxes.jsonl"; done
  for ((i = 0; i < nt; i++)); do _idx_req "$n" "$d" "/blockchain/transaction/byIndex/$i" | jq -c --argjson i "$i" '{key: ($i | tostring), value: .}' >> "$d/txs.jsonl"; done
  if [[ $nb -gt 0 ]]; then _idx_req "$n" "$d" "/blockchain/box/range?limit=$nb" > "$d/box_range.json"; else echo '[]' > "$d/box_range.json"; fi
  if [[ $nt -gt 0 ]]; then _idx_req "$n" "$d" "/blockchain/transaction/range?limit=$nt" > "$d/tx_range.json"; else echo '[]' > "$d/tx_range.json"; fi
  for t in $(jq -r '.value.assets[]?.tokenId' "$d/boxes.jsonl" | sort -u); do
    jq -cn --arg t "$t" --argjson info "$(_idx_req "$n" "$d" "/blockchain/token/byId/$t")" \
      --argjson all "$(_idx_req "$n" "$d" "/blockchain/box/byTokenId/$t?limit=$IDX_PAGE" | jq -c 'if .items then {ids: [.items[].boxId], total} else . end')" \
      --argjson uns "$(_idx_req "$n" "$d" "/blockchain/box/unspent/byTokenId/$t?limit=$IDX_PAGE" | jq -c 'if type == "array" then [.[].boxId] else . end')" \
      '{key: $t, value: {info: $info, boxes: $all, unspent: $uns}}' >> "$d/tokens.jsonl"
  done
  jq -n --slurpfile ih "$d/indexed.json" --slurpfile br "$d/box_range.json" --slurpfile tr "$d/tx_range.json" \
    --argjson nb "$nb" --argjson nt "$nt" \
    '{indexedHeight: $ih[0], box_count: $nb, tx_count: $nt, box_range: $br[0], tx_range: $tr[0]}' > "$d/global_only.json"
  jq -n --slurpfile g "$d/global_only.json" --slurpfile b "$d/boxes.jsonl" --slurpfile t "$d/txs.jsonl" --slurpfile k "$d/tokens.jsonl" \
    '{global: $g[0], boxes: ($b | from_entries), txs: ($t | from_entries), tokens: ($k | from_entries)}' > "$d/global.json"
  rm -f "$d/boxes.jsonl" "$d/txs.jsonl" "$d/tokens.jsonl" "$d/global_only.json" "$d/indexed.json" "$d/box_range.json" "$d/tx_range.json"; }

idx_addresses(){ jq -r '.boxes[]?.address // empty' "$1/global.json" | sort -u; }

# _idx_paged <node> <dir> <path> <address json> <ids jq>: page a {items,total} listing; prints {ids, total}
_idx_paged(){ local n="$1" d="$2" p="$3" a="$4" sel="$5" off=0 r tot ids='[]' got
  while :; do
    r="$(_idx_req "$n" "$d" "$p?offset=$off&limit=$IDX_PAGE" "$a")"
    jq -e 'has("items")' <<< "$r" >/dev/null 2>&1 || { echo "$r"; return; }
    tot="$(jq -r '.total' <<< "$r")"; ids="$(jq -c --argjson acc "$ids" "\$acc + [.items[] | $sel]" <<< "$r")"
    got="$(jq -r '.items | length' <<< "$r")"; off=$((off + IDX_PAGE))
    [[ "$got" -lt "$IDX_PAGE" || "$off" -ge "$tot" ]] && break
  done
  jq -cn --argjson ids "$ids" --argjson t "${tot:-0}" '{ids: $ids, total: $t}'; }

idx_snapshot_finish(){ local n="$1" d="$2" af="$3" out="$4" a aj bal txs boxes uns
  : > "$d/addr.jsonl"
  while IFS= read -r a; do [[ -n "$a" ]] || continue
    aj="$(jq -cn --arg a "$a" '$a')"
    bal="$(_idx_req "$n" "$d" /blockchain/balance "$aj" | jq -c 'if has("confirmed") then .confirmed else . end')"
    txs="$(_idx_paged "$n" "$d" /blockchain/transaction/byAddress "$aj" '.id')"
    boxes="$(_idx_paged "$n" "$d" /blockchain/box/byAddress "$aj" '.boxId')"
    uns="$(_idx_req "$n" "$d" "/blockchain/box/unspent/byAddress?limit=$IDX_PAGE" "$aj" \
      | jq -c 'if type == "array" then [.[] | {boxId, value, assets, globalIndex, inclusionHeight}] else . end')"
    jq -cn --arg a "$a" --argjson b "$bal" --argjson t "$txs" --argjson x "$boxes" --argjson u "$uns" \
      '{key: $a, value: {balance: $b, txs: $t, boxes: $x, unspent: $u}}' >> "$d/addr.jsonl"
  done < "$af"
  _idx_settle_rec "$n" > "$d/settle_after.json"
  jq -n --arg node "$n" --arg ver "$(rest "$n" /info | jq -r '.appVersion // "null"')" \
    --slurpfile g "$d/global.json" --slurpfile a "$d/addr.jsonl" --slurpfile sb "$d/settle_before.json" --slurpfile sa "$d/settle_after.json" \
    --slurpfile e "$d/errors.jsonl" \
    '{meta: {node: $node, appVersion: $ver}, settle: {before: $sb[0], after: $sa[0]}, errors: $e}
     + $g[0] + {addresses: ($a | from_entries)}' > "$out"
  rm -f "$d/addr.jsonl"; }
