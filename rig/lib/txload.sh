# rig/lib/txload.sh: a benign payment load and the observer that records where each payment went. Sourced by rig.sh.
# Honest wallets paying each other through /wallet/payment/send (the wallet chooses the inputs); nothing is crafted.
#
#   txload_fund <from> <nanoerg> <to>...   one payment from <from> to each <to> (kind "fund"), so their wallets can pay;
#                                          TXLOAD_FUND_SPLIT=<k> (default 1) splits each into k boxes of nanoerg/k, so a
#                                          wallet holds k confirmed boxes and a heavy load is not held to one box's chain
#   txload_start <rate> <node>...          background load: <rate> payments per 10 s on average (1-50), each from a
#                                          random listed node whose confirmed balance covers it, to another listed node;
#                                          TXLOAD_PER_NODE=1: one sender process per listed node, each paying only from
#                                          that node at rate/N (one sender's REST round trips cap a single loop near 2
#                                          ticks/s; parallel senders lift that ceiling); TXLOAD_CONFIRMED_ONLY=1:
#                                          each payment spends one confirmed box not spent before (no chains, no
#                                          unconfirmed change; amount TXLOAD_NANOERG, default 0.01 ERG in this mode)
#   txload_stop
#   txwatch_start <node>...                background observer, every TXWATCH_POLL_S (1) s per node: the best full block
#                                          (/info) and, on a node with input blocks (Matrix line), every input block id
#                                          new in /blocks/bestInputChain with its /blocks/<id>/inputBlockTransactionIds;
#                                          every TXWATCH_POOL_S (5) s the pool size /info reports (unconfirmedCount, no
#                                          extra call); and each input block the node logs as mined ("Input-block <id>
#                                          mined"), siblings included, with its transaction ids read from that node
#                                          (TXWATCH_MINED=0 turns this off)
#   txwatch_stop
#   txload_pools <node>...                 every node's unconfirmed pool, now (call before a relaunch: pools are memory)
#   txload_chain <node> <from height>      <node>'s blocks from that height to its tip, with their transaction ids
#
# Load shape (env): TXLOAD_NANOERG (0.1 ERG) per payment; TXLOAD_CHAIN_PCT (30): the share of ticks that send a chain of
# TXLOAD_CHAIN_LEN (3) payments from one wallet back to back, 0.3 s apart, so later ones may spend the earlier ones'
# unconfirmed change (dependent transactions); TXLOAD_SEED (1) seeds the payer / payee / chain choices.
# Files in $RIG_LOG_DIR (one JSON object per line):
#   txload.jsonl   per payment attempt {t_ms, kind: fund|pay, node, to, seq, chain_pos, chain_len, id|null, error|null
#                  (the node's text; a long one keeps its first 100 and last 300 characters),
#                  inputs, outputs} (inputs/outputs: box ids, from the payer's pool right after the send)
#   txwatch.jsonl  {t_ms, node, ev: "full", h, id} on each new best full block; {t_ms, node, ev: "input", ord, id, txs,
#                  credited} on each input block first seen in a node's best input chain (credited: the uncle ids the
#                  node's /blocks/bestInputChain "creditedUncles" lists for it, or "absent" without that field); {t_ms, node, ev: "pool", n};
#                  {t_ms, node, ev: "mined", id, txs, tries} per input block the node mined (txs null if the node
#                  never served them within 5 polls)
#   txload_pools.json {node: [tx ids]};  txload_chain.jsonl {h, id, ts, txs} per block of the named node's chain
# diag/txload_report.py joins them into one record per payment (txrecords.jsonl) and a summary line.
# The observer sees an input block only if it is in a node's best input chain at one of its polls.

declare -A TXL_ADDR
TXLOAD_PID=""; TXWATCH_PID=""
_txl_addr(){ [[ -n "${TXL_ADDR[$1]:-}" ]] || TXL_ADDR[$1]="$(address "$1")"; echo "${TXL_ADDR[$1]}"; }
# _txl_send <kind> <from> <to> <nanoerg> <seq> <pos> <len>: one payment, one line in txload.jsonl
_txl_send(){ local kind="$1" from="$2" to="$3" amt="$4" seq="$5" pos="$6" len="$7" split="${8:-1}" box="${9:-}" t out id="" err="" tx ins=null outs=null addr req raw
  addr="$(_txl_addr "$to")"; t=$(date +%s%3N)
  if [[ -z "$addr" ]]; then err="no address for $to"
  elif [[ -n "$box" ]]; then
    # spend exactly this confirmed box (inputsRaw from the payer's UTXO set), change back to the payer
    raw="$(rest "$from" "/utxo/byIdBinary/$box" | jq -r '.bytes // empty' 2>/dev/null)"
    if [[ -z "$raw" ]]; then out='{"detail":"box not in the payer'"'"'s UTXO set"}'
    else out="$(wallet "$from" /wallet/transaction/send "{\"requests\":[{\"address\":\"$addr\",\"value\":$amt}],\"inputsRaw\":[\"$raw\"],\"fee\":${TXLOAD_FEE:-1000000}}")"; fi
  else
    # split > 1: one transaction with that many outputs of amt/split each to the same address (separate boxes)
    req="$(jq -cn --arg a "$addr" --argjson v "$((amt / split))" --argjson k "$split" '[range($k) | {address: $a, value: $v}]')"
    out="$(wallet "$from" /wallet/payment/send "$req")"
  fi
  if [[ -n "$addr" ]]; then
    id="$(jq -r 'if type == "string" then . else empty end' <<< "$out" 2>/dev/null)"
    if [[ "$id" =~ ^[0-9a-f]{64}$ ]]; then
      tx="$(rest "$from" "/transactions/unconfirmed/byTransactionId/$id")"
      ins="$(jq -c '[.inputs[]?.boxId]' <<< "$tx" 2>/dev/null)"; outs="$(jq -c '[.outputs[]?.boxId]' <<< "$tx" 2>/dev/null)"
    else id=""; err="$(jq -r '.detail // .reason // tojson' <<< "$out" 2>/dev/null)"; err="${err:-${out:0:200}}"; fi
  fi
  jq -cn --argjson t "$t" --arg k "$kind" --arg n "$from" --arg to "$to" --argjson seq "$seq" --argjson pos "$pos" --argjson len "$len" \
     --arg id "$id" --arg err "$([[ ${#err} -gt 400 ]] && echo "${err:0:100} ... ${err: -300}" || echo "$err")" --argjson ins "${ins:-null}" --argjson outs "${outs:-null}" \
    '{t_ms: $t, kind: $k, node: $n, to: $to, seq: $seq, chain_pos: $pos, chain_len: $len,
      id: (if $id == "" then null else $id end), error: (if $err == "" then null else $err end), inputs: $ins, outputs: $outs}' \
    >> "$RIG_LOG_DIR/txload.jsonl"
  [[ -n "$id" ]]; }
txload_fund(){ local from="$1" amt="$2" to ok=0 n=0 k="${TXLOAD_FUND_SPLIT:-1}"; shift 2
  [[ "$k" =~ ^[0-9]+$ && $k -ge 1 && $k -le 300 ]] || { echo "[txload] TXLOAD_FUND_SPLIT '$k': 1-300"; return 1; }
  for to in "$@"; do n=$((n + 1)); _txl_send fund "$from" "$to" "$amt" 0 "$n" "$#" "$k" && ok=$((ok + 1)); sleep 0.3; done
  echo "[txload] funded $ok of $# wallets from $from ($amt nanoERG each, in $k box(es))"; }
# _txl_loop <rate per 10 s> <payer|-> <node>...: payer "-" = any listed node with the balance, else only that one
_txl_loop(){ local rate="$1" payer="$2"; shift 2; local nodes=("$@") amt="${TXLOAD_NANOERG:-100000000}" cpct="${TXLOAD_CHAIN_PCT:-30}" clen="${TXLOAD_CHAIN_LEN:-3}"
  local gap_ms=$((10000 / rate)) seq=0 next from to len k i cand need bal base="${TXL_SEQ_BASE:-0}" conf="${TXLOAD_CONFIRMED_ONLY:-0}" box
  local -A USED QUEUE LASTFILL
  # TXLOAD_CONFIRMED_ONLY=1: every payment spends one confirmed wallet box the sender has not spent before (inputsRaw),
  # never unconfirmed change, so no payment depends on another; no chains; default amount 0.01 ERG, so a box's
  # change is spendable again once confirmed
  [[ "$conf" == 1 ]] && { cpct=0; amt="${TXLOAD_NANOERG:-10000000}"; }
  RANDOM="$(( ${TXLOAD_SEED:-1} + base / 1000000 ))"; next=$(date +%s%3N); seq=$base
  while :; do
    seq=$((seq + 1)); len=1; (( RANDOM % 100 < cpct )) && len=$clen
    if [[ "$conf" == 1 ]]; then
      # payer: the listed nodes in a random rotation (or the fixed one), the first holding an unspent confirmed box
      from=""; box=""; k=$((RANDOM % ${#nodes[@]}))
      for ((i = 0; i < ${#nodes[@]}; i++)); do cand="${nodes[$(( (k + i) % ${#nodes[@]} ))]}"
        [[ "$payer" != - && "$cand" != "$payer" ]] && continue
        # refill from the wallet's confirmed unspent P2PK boxes (mining rewards excluded: their script is not P2PK)
        if [[ -z "${QUEUE[$cand]:-}" && $(( $(date +%s%3N) - ${LASTFILL[$cand]:-0} )) -ge 1000 ]]; then
          LASTFILL[$cand]=$(date +%s%3N)
          for box in $(wallet "$cand" "/wallet/boxes/unspent?minConfirmations=1&limit=1000" 2>/dev/null \
                       | jq -r --argjson need "$(( amt + ${TXLOAD_FEE:-1000000} ))" '.[]? | select(.box.value >= $need and (.box.ergoTree | startswith("0008cd"))) | .box.boxId' 2>/dev/null); do
            [[ -n "${USED[$box]:-}" ]] || QUEUE[$cand]+="$box "; done
        fi
        if [[ -n "${QUEUE[$cand]:-}" ]]; then box="${QUEUE[$cand]%% *}"; QUEUE[$cand]="${QUEUE[$cand]#* }"; USED[$box]=1; from="$cand"; break; fi
      done
      if [[ -n "$from" ]]; then
        to="$from"; while [[ "$to" == "$from" ]]; do to="${nodes[$((RANDOM % ${#nodes[@]}))]}"; done
        _txl_send pay "$from" "$to" "$amt" "$seq" 1 1 1 "$box"
      else
        jq -cn --argjson t "$(date +%s%3N)" --argjson seq "$seq" '{t_ms: $t, kind: "skip", seq: $seq, error: "no unspent confirmed box"}' >> "$RIG_LOG_DIR/txload.jsonl"
      fi
      next=$((next + gap_ms / 2 + RANDOM % (gap_ms + 1))); _sleep_until "$next"
      continue
    fi
    need=$(( (amt + 2000000) * len * 2 ))
    # payer: the listed nodes in a random rotation, the first whose confirmed balance covers the tick
    from=""; k=$((RANDOM % ${#nodes[@]}))
    for ((i = 0; i < ${#nodes[@]}; i++)); do cand="${nodes[$(( (k + i) % ${#nodes[@]} ))]}"
      [[ "$payer" != - && "$cand" != "$payer" ]] && continue
      bal="$(balance "$cand" 2>/dev/null)"; [[ "$bal" =~ ^[0-9]+$ && $bal -ge $need ]] && { from="$cand"; break; }; done
    if [[ -n "$from" ]]; then
      to="$from"; while [[ "$to" == "$from" ]]; do to="${nodes[$((RANDOM % ${#nodes[@]}))]}"; done
      for ((i = 1; i <= len; i++)); do _txl_send pay "$from" "$to" "$amt" "$seq" "$i" "$len"; ((i < len)) && sleep 0.3; done
    else
      jq -cn --argjson t "$(date +%s%3N)" --argjson seq "$seq" '{t_ms: $t, kind: "skip", seq: $seq, error: "no wallet with a confirmed balance covering the tick"}' >> "$RIG_LOG_DIR/txload.jsonl"
    fi
    # Poisson-ish spacing around the mean gap (uniform 0.5-1.5 x), kept on schedule
    next=$((next + gap_ms / 2 + RANDOM % (gap_ms + 1))); _sleep_until "$next"
  done; }
txload_start(){ local rate="$1" n i r; shift
  [[ "$rate" =~ ^[0-9]+$ && $rate -ge 1 && $rate -le 50 ]] || { echo "[txload] rate '$rate': 1-50 payments per 10 s"; return 1; }
  [[ $# -ge 2 ]] || { echo "[txload] needs at least two nodes"; return 1; }
  for n in "$@"; do _txl_addr "$n" >/dev/null; done
  TXLOAD_PID=""
  if [[ "${TXLOAD_PER_NODE:-0}" == 1 ]]; then
    # one sender per payer, rate/N each (at least 1); seq numbers kept apart per sender (base i * 1000000)
    i=0; r=$(( rate / $# )); (( r >= 1 )) || r=1
    for n in "$@"; do i=$((i + 1))
      TXL_SEQ_BASE=$((i * 1000000)) _txl_loop "$r" "$n" "$@" >> "$RIG_LOG_DIR/txload.err" 2>&1 &
      TXLOAD_PID+="${TXLOAD_PID:+ }$!"; BG_PIDS+=("$!"); done
  else
    _txl_loop "$rate" - "$@" >> "$RIG_LOG_DIR/txload.err" 2>&1 & TXLOAD_PID=$!; BG_PIDS+=("$TXLOAD_PID")
  fi
  mark txload-start; echo "[txload] started: $rate per 10 s among $* ($([[ "${TXLOAD_PER_NODE:-0}" == 1 ]] && echo "one sender per node, $r each" || echo "one sender"); $([[ "${TXLOAD_CONFIRMED_ONLY:-0}" == 1 ]] && echo "confirmed boxes only, no chains" || echo "chains of ${TXLOAD_CHAIN_LEN:-3} in ${TXLOAD_CHAIN_PCT:-30}% of ticks"); pid $TXLOAD_PID)"; }
txload_stop(){ [[ -n "$TXLOAD_PID" ]] || return 0; local p; for p in $TXLOAD_PID; do kill "$p" 2>/dev/null; wait "$p" 2>/dev/null; done; TXLOAD_PID=""
  mark txload-stop; echo "[txload] stopped: $(grep -c '"kind":"pay"' "$RIG_LOG_DIR/txload.jsonl" 2>/dev/null) payment attempts"; }
_txw_loop(){ local nodes=("$@") x info full ic ord id txs t cu pool lastpool=0 pool_ms=$(( ${TXWATCH_POOL_S:-5} * 1000 )) logf sz k
  declare -A LASTF SEEN NOIB LOGOFF PEND
  # mined input blocks are read from the logs' current ends on: only blocks mined while the observer runs
  for x in "${nodes[@]}"; do logf="$RIG_LOG_DIR/node_$x.log"; [[ -f "$logf" ]] && LOGOFF[$x]=$(stat -c %s "$logf"); done
  while :; do
    t=$(date +%s%3N); pool=0; (( t - lastpool >= pool_ms )) && { pool=1; lastpool=$t; }
    for x in "${nodes[@]}"; do
      info="$(rest "$x" /info 2>/dev/null)"; full="$(jq -r '"\(.fullHeight // "")/\(.bestFullHeaderId // "")"' <<< "$info" 2>/dev/null)"
      if [[ "$full" =~ ^[0-9]+/[0-9a-f]{64}$ && "$full" != "${LASTF[$x]:-}" ]]; then LASTF[$x]="$full"
        printf '{"t_ms":%s,"node":"%s","ev":"full","h":%s,"id":"%s"}\n' "$(date +%s%3N)" "$x" "${full%/*}" "${full#*/}"; fi
      if (( pool )); then k="$(jq -r '.unconfirmedCount // empty' <<< "$info" 2>/dev/null)"
        [[ "$k" =~ ^[0-9]+$ ]] && printf '{"t_ms":%s,"node":"%s","ev":"pool","n":%s}\n' "$(date +%s%3N)" "$x" "$k"; fi
      [[ -n "${NOIB[$x]:-}" ]] && continue
      # input blocks this node mined (its own log), siblings included: their transaction ids, read from this node; an id
      # the node does not serve yet is retried on the next polls (5 in all)
      logf="$RIG_LOG_DIR/node_$x.log"
      if [[ "${TXWATCH_MINED:-1}" == 1 && -f "$logf" ]]; then sz=$(stat -c %s "$logf")
        if (( sz > ${LOGOFF[$x]:-0} )); then
          for id in $(tail -c +"$(( ${LOGOFF[$x]:-0} + 1 ))" "$logf" | head -c "$(( sz - ${LOGOFF[$x]:-0} ))" \
                      | grep -oE 'Input-block [0-9a-f]{64} mined @' | cut -d' ' -f2); do PEND[$x/$id]=0; done
          LOGOFF[$x]=$sz; fi
        for k in "${!PEND[@]}"; do [[ "$k" == "$x/"* ]] || continue; id="${k#*/}"
          txs="$(rest "$x" "/blocks/$id/inputBlockTransactionIds" | jq -c 'if type == "array" then . else null end' 2>/dev/null)"
          PEND[$k]=$(( PEND[$k] + 1 ))
          if [[ -n "$txs" && "$txs" != null ]] || (( PEND[$k] >= 5 )); then
            printf '{"t_ms":%s,"node":"%s","ev":"mined","id":"%s","txs":%s,"tries":%s}\n' "$(date +%s%3N)" "$x" "$id" "${txs:-null}" "${PEND[$k]}"
            unset "PEND[$k]"; fi
        done
      fi
      ic="$(rest "$x" /blocks/bestInputChain 2>/dev/null)"
      # a node that answers /info but has no such route (a release jar) is not asked again
      if ! jq -e 'has("bestOrdering")' <<< "$ic" >/dev/null 2>&1; then [[ -n "$info" && -n "$ic" ]] && NOIB[$x]=1; continue; fi
      ord="$(jq -r '.bestOrdering // empty' <<< "$ic" 2>/dev/null)"; [[ -n "$ord" ]] || continue
      for id in $(jq -r '.bestInputBlocks[]? // empty' <<< "$ic" 2>/dev/null); do
        [[ -n "${SEEN[$x/$id]:-}" ]] && continue; SEEN[$x/$id]=1; t=$(date +%s%3N)
        txs="$(rest "$x" "/blocks/$id/inputBlockTransactionIds" | jq -c 'if type == "array" then . else null end' 2>/dev/null)"
        # "credited": the uncles this node credits to the block (field "creditedUncles" of /blocks/bestInputChain, which
        # only a node running the uncles prototype with its setting on serves); absent = the node does not report it
        cu="$(jq -c --arg i "$id" 'if has("creditedUncles") then (.creditedUncles[$i] // []) else "absent" end' <<< "$ic" 2>/dev/null)"
        printf '{"t_ms":%s,"node":"%s","ev":"input","ord":"%s","id":"%s","txs":%s,"credited":%s}\n' "$t" "$x" "$ord" "$id" "${txs:-null}" "${cu:-null}"
      done
    done
    sleep "${TXWATCH_POLL_S:-1}"
  done; }
txwatch_start(){ _txw_loop "$@" >> "$RIG_LOG_DIR/txwatch.jsonl" 2>> "$RIG_LOG_DIR/txload.err" & TXWATCH_PID=$!; BG_PIDS+=("$TXWATCH_PID")
  echo "[txwatch] started on $* (every ${TXWATCH_POLL_S:-1} s; pid $TXWATCH_PID)"; }
txwatch_stop(){ [[ -n "$TXWATCH_PID" ]] || return 0; kill "$TXWATCH_PID" 2>/dev/null; wait "$TXWATCH_PID" 2>/dev/null; TXWATCH_PID=""
  echo "[txwatch] stopped: $(grep -c '"ev":"input"' "$RIG_LOG_DIR/txwatch.jsonl" 2>/dev/null) input-block and $(grep -c '"ev":"full"' "$RIG_LOG_DIR/txwatch.jsonl" 2>/dev/null) best-block observations"; }
txload_pools(){ local x
  { for x in "$@"; do printf '%s\t%s\n' "$x" "$(mempool_ids "$x" | paste -sd, -)"; done; } \
    | jq -R -s 'split("\n") | map(select(length > 0) | split("\t") | {(.[0]): (.[1] | if . == "" then [] else split(",") end)}) | add // {}' \
    > "$RIG_LOG_DIR/txload_pools.json"; }
txload_chain(){ local x="$1" h hid blk
  : > "$RIG_LOG_DIR/txload_chain.jsonl"
  for ((h = $2; h <= $(full_height "$x"); h++)); do hid="$(header_at "$x" "$h")"; [[ -n "$hid" ]] || continue
    blk="$(rest "$x" "/blocks/$hid")"
    jq -c --argjson h "$h" --arg id "$hid" '{h: $h, id: $id, ts: .header.timestamp, txs: [.blockTransactions.transactions[]?.id]}' <<< "$blk" \
      >> "$RIG_LOG_DIR/txload_chain.jsonl" 2>/dev/null
  done; }
