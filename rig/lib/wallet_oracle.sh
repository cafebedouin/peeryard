# wallet_oracle.sh: a differential wallet oracle (rig/WALLET-ORACLE.md). Sourced by a hook (wallet_snapshot,
# wallet_settle and wallet_oracle use the rig's `rest` and `wallet`) or by tests/wallet_oracle.sh (wallet_cmp only,
# no node).
#
#   wallet_same_addresses <s> <r>          precondition: both list the same non-empty /wallet/addresses; prints
#                                          ADDR-SAME:<n> or ADDR-DIFF:<s>=<n>:<r>=<n> / ADDR-NONE; returns 0 on SAME
#   wallet_snapshot <node> <file>          one wallet view as JSON (the fields below), /info read before and after
#   wallet_settle <s> <r> [window_s=120]   wait for one best full block, walletHeight == fullHeight on both and the
#                                          same mempool ids; prints SETTLED@<h> or NOT-SETTLED: <why>; returns 0 / 1
#   wallet_cmp <subject.json> <reference.json>
#                                          prints "[wallet-oracle] SAME@<h>:<n-boxes>", "[wallet-oracle] DIFF@<h>:
#                                          <field>: subject=<...> reference=<...>" (then one indented line per
#                                          differing field) or "[wallet-oracle] INCONCLUSIVE: <why>"; returns 0 / 1 / 3
#   wallet_oracle <s> <r> [window_s] [dir] settle, snapshot both, compare (a snapshot pair that a block split is
#                                          retaken, up to 3 times); sets WO_LINE (the verdict line) and WO_RESULT
#                                          (SAME, DIFF or INCONCLUSIVE); returns as wallet_cmp
#
# Snapshot fields: node, info and info_after ({fullHeight, bestFullHeaderId}), walletHeight, mempool (sorted ids),
# addresses (sorted), balance and balanceUnconfirmed ({balance, assets}), unspent (sorted by boxId: boxId, value,
# assets, inclusionHeight, onchain, creationTransaction; minConfirmations=-1, so boxes of mempool transactions too),
# transactions (sorted by id: id, inclusionHeight; inclusion heights 0..fullHeight), scans (sorted scanId, scanName).
# A read that did not return JSON of the expected type is null, and the comparator reports the snapshot incomplete.
# WO_IGNORE_MEMPOOL=1 drops the same-mempool settle rule (wallet_settle and wallet_cmp): for a comparison taken while
# a payment is pending and the subject's pool may have lost it (a restart empties the pool on 6.0.6), where the
# question is the wallet's own unconfirmed view.

WO_PAGE=2500   # /wallet/boxes/unspent's maximum limit

_wo_json(){ jq -ce "if type == \"$1\" then . else error end" 2>/dev/null || echo null; }   # stdin JSON of type $1, else null

wallet_same_addresses(){ local a b na nb
  a=$(wallet "$1" /wallet/addresses | _wo_json array); b=$(wallet "$2" /wallet/addresses | _wo_json array)
  na=$(jq 'length? // 0' <<< "$a"); nb=$(jq 'length? // 0' <<< "$b")
  if [[ "$na" == 0 || "$nb" == 0 ]]; then echo "ADDR-NONE:$1=$na:$2=$nb"; return 1; fi
  if [[ "$(jq -c sort <<< "$a")" == "$(jq -c sort <<< "$b")" ]]; then echo "ADDR-SAME:$na"; return 0; fi
  echo "ADDR-DIFF:$1=$na:$2=$nb"; return 1; }

_wo_info(){ rest "$1" /info | jq -c '{fullHeight: (.fullHeight // 0), bestFullHeaderId: (.bestFullHeaderId // null)}' 2>/dev/null || echo null; }

wallet_snapshot(){ local n="$1" out="$2" d i0 h off page k
  d=$(mktemp -d "${TMPDIR:-/tmp}/wo-snap.XXXXXX")
  i0=$(_wo_info "$n"); h=$(jq -r '.fullHeight? // 0' <<< "$i0")
  wallet "$n" /wallet/status | _wo_json object > "$d/status"
  wallet "$n" /wallet/addresses | _wo_json array > "$d/addresses"
  wallet "$n" /wallet/balances | _wo_json object > "$d/balance"
  wallet "$n" /wallet/balances/withUnconfirmed | _wo_json object > "$d/balanceU"
  off=0; : > "$d/unspent.pages"
  while :; do
    page=$(wallet "$n" "/wallet/boxes/unspent?minConfirmations=-1&limit=$WO_PAGE&offset=$off" | _wo_json array)
    [[ "$page" == null ]] && { echo null > "$d/unspent.pages"; break; }
    echo "$page" >> "$d/unspent.pages"; k=$(jq length <<< "$page"); [[ "$k" -lt "$WO_PAGE" ]] && break; off=$((off + k))
  done
  wallet "$n" "/wallet/transactions?minInclusionHeight=0&maxInclusionHeight=$h" | _wo_json array > "$d/txs"
  wallet "$n" /scan/listAll | _wo_json array > "$d/scans"
  rest "$n" '/transactions/unconfirmed?limit=10000' | _wo_json array > "$d/pool"
  _wo_info "$n" > "$d/info_after"; echo "$i0" > "$d/info"
  jq -n --arg node "$n" --slurpfile i "$d/info" --slurpfile ia "$d/info_after" --slurpfile st "$d/status" \
     --slurpfile ad "$d/addresses" --slurpfile b "$d/balance" --slurpfile bu "$d/balanceU" \
     --slurpfile u "$d/unspent.pages" --slurpfile t "$d/txs" --slurpfile sc "$d/scans" --slurpfile p "$d/pool" '
    def bal($x): if $x == null then null else {balance: $x.balance, assets: ($x.assets // {})} end;
    def assets($a): ($a // []) | map({tokenId, amount}) | sort_by(.tokenId);
    {node: $node, info: $i[0], info_after: $ia[0],
     walletHeight: ($st[0].walletHeight? // null),
     mempool: (if $p[0] == null then null else [$p[0][].id] | sort end),
     addresses: (if $ad[0] == null then null else $ad[0] | sort end),
     balance: bal($b[0]), balanceUnconfirmed: bal($bu[0]),
     unspent: (if any($u[]; . == null) then null else [$u[][] | {boxId: .box.boxId, value: .box.value,
               assets: assets(.box.assets), inclusionHeight, onchain, creationTransaction}] | sort_by(.boxId) end),
     transactions: (if $t[0] == null then null else [$t[0][] | {id, inclusionHeight}] | sort_by(.id) end),
     scans: (if $sc[0] == null then null else [$sc[0][] | {scanId, scanName}] | sort_by(.scanId) end)}' > "$out"
  rm -rf "$d"; }

wallet_settle(){ local s="$1" r="$2" end=$((SECONDS + ${3:-120})) why is ir ws wr ps pr
  while :; do
    is=$(_wo_info "$s"); ir=$(_wo_info "$r")
    ws=$(wallet "$s" /wallet/status | jq -r '.walletHeight // "none"' 2>/dev/null); wr=$(wallet "$r" /wallet/status | jq -r '.walletHeight // "none"' 2>/dev/null)
    ps=$(rest "$s" '/transactions/unconfirmed?limit=10000' | jq -c '[.[]?.id] | sort' 2>/dev/null)
    pr=$(rest "$r" '/transactions/unconfirmed?limit=10000' | jq -c '[.[]?.id] | sort' 2>/dev/null)
    why=$(jq -nr --argjson is "$is" --argjson ir "$ir" --arg ws "$ws" --arg wr "$wr" --arg ps "$ps" --arg pr "$pr" --arg im "${WO_IGNORE_MEMPOOL:-0}" '
      if ($is.fullHeight // 0) < 1 or ($ir.fullHeight // 0) < 1 then "no full block on one node"
      elif $is.bestFullHeaderId != $ir.bestFullHeaderId then "best full blocks differ (\($is.fullHeight), \($ir.fullHeight))"
      elif $ws != ($is.fullHeight | tostring) or $wr != ($ir.fullHeight | tostring) then "wallet heights \($ws), \($wr) at full height \($is.fullHeight)"
      elif $ps != $pr and $im != "1" then "mempools differ"
      else "" end' 2>/dev/null || echo "unreadable")
    [[ -z "$why" ]] && { echo "SETTLED@$(jq -r .fullHeight <<< "$is")"; return 0; }
    [[ $SECONDS -ge $end ]] && { echo "NOT-SETTLED: $why"; return 1; }
    sleep 3
  done; }

# The comparison itself: a pure function of two snapshot files.
wallet_cmp(){ local res kind
  res=$(jq -n --slurpfile S "$1" --slurpfile R "$2" --arg im "${WO_IGNORE_MEMPOOL:-0}" '
    # lists compared as sets: sorted here too, so a hand-made or reordered snapshot compares by content
    def norm: if type != "object" then . else
      .addresses |= (if . == null then . else sort end) | .mempool |= (if . == null then . else sort end)
      | .unspent |= (if . == null then . else sort_by(.boxId) end) | .transactions |= (if . == null then . else sort_by(.id) end)
      | .scans |= (if . == null then . else sort_by(.scanId) end) end;
    ($S[0] | norm) as $s | ($R[0] | norm) as $r |
    def id8: if . == null then "none" else tostring | .[0:8] end;
    def fields: ["addresses", "balance", "balanceUnconfirmed", "unspent", "transactions", "scans"];
    def keyof($f): {unspent: "boxId", transactions: "id", scans: "scanId"}[$f];
    def missing($x): [fields[], "walletHeight", "info", "info_after", "mempool"] | map(select($x[.] == null));
    def unsettled:
      if $s.info != $s.info_after then "subject /info changed during its snapshot (\($s.info.fullHeight) -> \($s.info_after.fullHeight))"
      elif $r.info != $r.info_after then "reference /info changed during its snapshot (\($r.info.fullHeight) -> \($r.info_after.fullHeight))"
      elif $s.info.bestFullHeaderId != $r.info.bestFullHeaderId then
        "best full blocks differ: subject=\($s.info.fullHeight):\($s.info.bestFullHeaderId | id8) reference=\($r.info.fullHeight):\($r.info.bestFullHeaderId | id8)"
      elif $s.walletHeight != $s.info.fullHeight then "subject wallet height \($s.walletHeight) at full height \($s.info.fullHeight)"
      elif $r.walletHeight != $r.info.fullHeight then "reference wallet height \($r.walletHeight) at full height \($r.info.fullHeight)"
      elif $s.mempool != $r.mempool and $im != "1" then "mempools differ: subject=\($s.mempool | length) reference=\($r.mempool | length) transactions"
      else null end;
    # a list field: counts, the entries only on one side, and the entries under one key with different contents
    def listdiff($f):
      ($s[$f] | map({key: (.[keyof($f)] | tostring), value: .}) | from_entries) as $a |
      ($r[$f] | map({key: (.[keyof($f)] | tostring), value: .}) | from_entries) as $b |
      ([$a | keys[] | select($b[.] == null)]) as $oa | ([$b | keys[] | select($a[.] == null)]) as $ob |
      ([$a | keys[] | select($b[.] != null and $a[.] != $b[.])]) as $ch |
      def side($n; $only): "\($n) (\($only | length) only here\(if ($only | length) > 0 then ", e.g. \($only[0] | id8)" else "" end)\(if ($ch | length) > 0 then ", \($ch | length) changed, e.g. \($ch[0] | id8)" else "" end))";
      {subject: side($s[$f] | length; $oa), reference: side($r[$f] | length; $ob)};
    def show($f): if $f == "addresses" then
        {subject: "\($s.addresses | length) (\([$s.addresses[] | select(. as $x | $r.addresses | index($x) | not)] | length) only here)",
         reference: "\($r.addresses | length) (\([$r.addresses[] | select(. as $x | $s.addresses | index($x) | not)] | length) only here)"}
      elif keyof($f) then listdiff($f)
      else {subject: ($s[$f] | tojson), reference: ($r[$f] | tojson)} end;
    if ($s | type) != "object" or ($r | type) != "object" then {kind: "INCONCLUSIVE", why: "a snapshot is not a JSON object"}
    elif (missing($s) | length) > 0 then {kind: "INCONCLUSIVE", why: "subject snapshot incomplete: \(missing($s) | join(","))"}
    elif (missing($r) | length) > 0 then {kind: "INCONCLUSIVE", why: "reference snapshot incomplete: \(missing($r) | join(","))"}
    elif unsettled != null then {kind: "INCONCLUSIVE", why: "not settled: \(unsettled)"}
    else [fields[] | select($s[.] != $r[.])] as $d |
      if ($d | length) == 0 then {kind: "SAME", h: $s.info.fullHeight, n: ($s.unspent | length)}
      else {kind: "DIFF", h: $s.info.fullHeight, diffs: [$d[] | {field: .} + show(.)]} end
    end' 2>&1) || { echo "[wallet-oracle] INCONCLUSIVE: comparator error: $(head -1 <<< "$res")"; return 3; }
  kind=$(jq -r .kind <<< "$res")
  case "$kind" in
    SAME) jq -r '"[wallet-oracle] SAME@\(.h):\(.n)"' <<< "$res"; return 0 ;;
    DIFF) jq -r '"[wallet-oracle] DIFF@\(.h): \(.diffs[0].field): subject=\(.diffs[0].subject) reference=\(.diffs[0].reference)",
                 (.diffs[] | "[wallet-oracle]   \(.field): subject=\(.subject) reference=\(.reference)")' <<< "$res"; return 1 ;;
    *) jq -r '"[wallet-oracle] INCONCLUSIVE: \(.why)"' <<< "$res"; return 3 ;;
  esac; }

wallet_oracle(){ local s="$1" r="$2" win="${3:-120}" dir="${4:-${RIG_LOG_DIR:-${TMPDIR:-/tmp}}/wallet-oracle}" st out rc=3 try
  mkdir -p "$dir"; WO_LINE=""; WO_RESULT=INCONCLUSIVE
  if ! st=$(wallet_settle "$s" "$r" "$win"); then
    WO_LINE="[wallet-oracle] INCONCLUSIVE: not settled: ${st#NOT-SETTLED: }"
    echo "$WO_LINE"; return 3; fi
  for try in 1 2 3; do
    wallet_snapshot "$s" "$dir/subject-$s.json"; wallet_snapshot "$r" "$dir/reference-$r.json"
    out=$(wallet_cmp "$dir/subject-$s.json" "$dir/reference-$r.json"); rc=$?
    [[ $rc == 3 && "$out" == *"changed during its snapshot"* && $try -lt 3 ]] || break
    wallet_settle "$s" "$r" "$win" >/dev/null
  done
  echo "$out"; WO_LINE=$(head -1 <<< "$out")
  [[ $rc == 1 ]] && wo_explain "$s" "$r" "$dir/subject-$s.json" "$dir/reference-$r.json"
  case $rc in 0) WO_RESULT=SAME ;; 1) WO_RESULT=DIFF ;; *) WO_RESULT=INCONCLUSIVE ;; esac
  return $rc; }

# ---- staging shared by the wallet-oracle examples (rig/WALLET-ORACLE.md, "Events") ----
# wo_history <s> <r> <p> <miner>: with the miner mining, give the subject's wallet something worth checking: matured
# mining rewards (>= WO_MIN_REWARDS nanoERG, default 10 ERG, on both s and r), three payments s -> p (spent boxes)
# and three payments p -> s (received boxes from a foreign wallet), all confirmed (the miner's pool drains and two
# more blocks follow). Prints one line per step; returns 1 (with WO_WHY set) when a step did not happen.
wo_history(){ local s="$1" r="$2" p="$3" m="$4" b i id sent=0 got=0 h end
  WO_WHY=""
  if ! b=$(wait_balance "$s" "${WO_MIN_REWARDS:-10000000000}" 300); then WO_WHY="no matured rewards on $s ($b)"; return 1; fi
  echo "[wo] $s holds $b nanoERG of matured rewards at height $(full_height "$s"); $r holds $(balance "$r")"
  local ids=()
  for i in 1 2 3; do id=$(pay "$s" "$p" 2000000000); [[ "$id" =~ ^[0-9a-f]{64}$ ]] && { sent=$((sent + 1)); ids+=("$id"); } || echo "[wo]   $s -> $p $i rejected: $id"; sleep 1; done
  # WO_HISTORY_WAIT (default 300 s): a subject one hop further from the miner (the fork example) needs longer than 120 s.
  # After 60 s, a payment still only in the subject's pool is handed to the miner (seen on a hosted runner: one of three
  # stayed in S's pool and never reached M, two hops away)
  if ! b=$(wait_balance "$p" $((sent * 2000000000)) 60); then
    for id in "${ids[@]}"; do wo_push "$m" "$id" "$s"; done
    b=$(wait_balance "$p" $((sent * 2000000000)) "${WO_HISTORY_WAIT:-300}"); fi
  if [[ "${b:-0}" -lt $((sent * 2000000000)) || $sent -lt 1 ]]; then
    WO_WHY="$s -> $p payments: $sent sent, $p balance $b; pools: $s=$(mempool_size "$s") $m=$(mempool_size "$m"); $(for id in "${ids[@]}"; do printf '%s:%s=%s,%s=%s ' "${id:0:8}" "$s" "$(mempool_ids "$s" | grep -qx "$id" && echo pool || echo -)" "$m" "$(mempool_ids "$m" | grep -qx "$id" && echo pool || echo -)"; done)"; return 1; fi
  for i in 1 2 3; do id=$(pay "$p" "$s" 500000000); [[ "$id" =~ ^[0-9a-f]{64}$ ]] && got=$((got + 1)) || echo "[wo]   $p -> $s $i rejected: $id"; sleep 1; done
  [[ $got -ge 1 ]] || { WO_WHY="no $p -> $s payment accepted"; return 1; }
  end=$((SECONDS + 120)); while [[ $SECONDS -lt $end && "$(mempool_size "$m")" != 0 ]]; do sleep 2; done
  h=$(full_height "$m"); end=$((SECONDS + 60)); while [[ $SECONDS -lt $end && "$(full_height "$m")" -lt $((h + 2)) ]]; do sleep 1; done
  [[ "$(mempool_size "$m")" == 0 ]] || { WO_WHY="$m's pool did not drain ($(mempool_size "$m") left)"; return 1; }
  echo "[wo] history: $sent payments $s -> $p (spent boxes), $got payments $p -> $s (received), confirmed by height $(full_height "$m")"; }

# wo_push <miner> <txid> <node>...: when the miner's pool lacks an unconfirmed transaction that one of the nodes'
# pools holds, submit that same signed transaction to the miner (POST /transactions; an honest rebroadcast, nothing is
# built or altered) and print one line saying so. A node's pool is not re-gossiped on a timer, so a payment that missed
# the miner (it was relaunched, or a relay dropped it) would otherwise wait out the staging window.
wo_push(){ local m="$1" id="$2" n tx r; shift 2
  [[ -n "$id" ]] || return 0
  mempool_ids "$m" | grep -qx "$id" && return 0
  for n in "$@"; do
    # a node without it answers with an error object, so the answer must be the transaction itself
    tx=$(rest "$n" "/transactions/unconfirmed/byTransactionId/$id" | jq -c --arg id "$id" 'select(type == "object" and .id == $id)' 2>/dev/null)
    [[ -n "$tx" ]] || continue
    r=$(wallet "$m" /transactions "$tx" | jq -c . 2>/dev/null | head -c 200)
    echo "[wo] re-submitted ${id:0:8} from $n's pool to $m: ${r:-no answer}"; return 0
  done
  echo "[wo] ${id:0:8} is in no pool of $* (not re-submitted)"; }

# wo_same_tip <timeout_s> <node>...: wait until every node reports the first node's best full block (no miner running)
wo_same_tip(){ local end=$((SECONDS + $1)) n t ok; shift
  while :; do ok=1; t=$(applied_header "$1"); [[ -n "$t" ]] || ok=0
    for n in "$@"; do [[ "$(applied_header "$n")" == "$t" ]] || ok=0; done
    [[ $ok == 1 ]] && return 0; [[ $SECONDS -ge $end ]] && return 1; sleep 2; done; }

# wo_pending <s> <r> <p>: one payment s -> p that is left unconfirmed (call it with no miner running); WO_PENDING is
# its id. Returns 1 (WO_WHY set) unless both s's and r's pools list it within 30 s.
wo_pending(){ local s="$1" r="$2" p="$3" end
  WO_PENDING=$(pay "$s" "$p" 300000000); WO_WHY=""
  [[ "$WO_PENDING" =~ ^[0-9a-f]{64}$ ]] || { WO_WHY="pending payment rejected: $WO_PENDING"; return 1; }
  end=$((SECONDS + 30))
  while [[ $SECONDS -lt $end ]]; do
    mempool_ids "$s" | grep -qx "$WO_PENDING" && mempool_ids "$r" | grep -qx "$WO_PENDING" && { echo "[wo] pending payment ${WO_PENDING:0:8} in $s's and $r's pools"; return 0; }
    sleep 1
  done
  WO_WHY="pending payment ${WO_PENDING:0:8} not in both pools"; return 1; }

# wo_redial <timeout_s> <miner> <node>...: after the miner's relaunch, wait until each node lists the miner as a
# connected peer. The miner has no knownPeers, so it does not dial back, and a follower's own retry may have hit the
# miner while it was down: a node still without it after 10 s is re-dialled (POST /peers/connect, as the rig's
# bring-up does), every 10 s. Returns 1 when one is still missing at the deadline.
wo_redial(){ local end=$((SECONDS + $1)) m="$2" n ok next=$((SECONDS + 10)); shift 2
  while :; do ok=1
    for n in "$@"; do [[ " $(peers_of "$n") " == *" $m "* ]] && continue; ok=0
      [[ $SECONDS -ge $next ]] && wallet "$n" /peers/connect "\"${IP[$m]}:${P2P[$m]}\"" >/dev/null; done
    [[ $SECONDS -ge $next ]] && next=$((SECONDS + 10))
    [[ $ok == 1 ]] && return 0; [[ $SECONDS -ge $end ]] && { echo "[wo] redial: $m still not a peer of every node"; return 1; }
    sleep 2; done; }

# wo_confirm <miner> <blocks> <node>...: mine (poll WO_POLL, default 2s) until the miner's pool is empty, it is at least
# <blocks> blocks higher, and every node has reached that height (so the blocks reached them); then stop it, re-dial the nodes to the relaunched
# miner and wait for one tip again. Prints the heights; returns 1 when the nodes never reached one tip.
wo_confirm(){ local m="$1" k="$2" h0 end ok=0 n; shift 2
  h0=$(full_height "$m"); start_mining "$m" "${WO_POLL:-2s}" >/dev/null; settle_height_back "$m"; wo_redial 60 "$m" "$@"
  # start_mining relaunched the miner with an empty pool: the pending payment (WO_PENDING) goes back to it from a peer
  # that holds it, once now and once more after 30 s if still missing and unconfirmed
  local pushed=0; wo_push "$m" "${WO_PENDING:-}" "$@"
  end=$((SECONDS + 180))
  while [[ $SECONDS -lt $end ]]; do
    if [[ $pushed == 0 && $SECONDS -ge $((end - 150)) && -n "${WO_PENDING:-}" ]]; then pushed=1
      [[ "$(wallet "$m" "/wallet/transactionById?id=$WO_PENDING" | jq -r '.inclusionHeight // empty' 2>/dev/null)" =~ ^[0-9]+$ ]] || wo_push "$m" "$WO_PENDING" "$@"; fi
    if [[ "$(full_height "$m")" -ge $((h0 + k)) && "$(mempool_size "$m")" == 0 ]]; then
      ok=1; for n in "$@"; do [[ "$(full_height "$n")" -ge $((h0 + k)) ]] || ok=0; done; [[ $ok == 1 ]] && break; fi
    sleep 2
  done
  stop_mining "$m" >/dev/null; settle_height_back "$m"; wo_redial 60 "$m" "$@"
  wo_same_tip 90 "$m" "$@"; ok=$?
  echo "[wo] $m mined from $h0 to $(full_height "$m"), pool $(mempool_size "$m"); one tip with $*: $([[ $ok == 0 ]] && echo yes || echo no)"
  return $ok; }

# wo_explain <s> <r> <subject.json> <reference.json> [max=3]: after a DIFF, for up to <max> unspent boxes listed by
# one side only, print what the other side's wallet records for that box (/wallet/boxes, spent boxes included:
# spent, spendingTransaction, spendingHeight, inclusionHeight; "absent" when it lists none) and whether each node's
# UTXO set holds it (/utxo/byId). Evidence for reading the DIFF, not part of the verdict.
wo_explain(){ local s="$1" r="$2" fs="$3" fr="$4" max="${5:-3}" side id other off page k rec
  for side in reference subject; do
    if [[ $side == reference ]]; then other="$s"
      mapfile -t ids < <(jq -nr --slurpfile a "$fr" --slurpfile b "$fs" '[$b[0].unspent[].boxId] as $o | $a[0].unspent[].boxId | select(. as $x | $o | index($x) | not)' | head -n "$max")
    else other="$r"
      mapfile -t ids < <(jq -nr --slurpfile a "$fs" --slurpfile b "$fr" '[$b[0].unspent[].boxId] as $o | $a[0].unspent[].boxId | select(. as $x | $o | index($x) | not)' | head -n "$max")
    fi
    for id in "${ids[@]}"; do
      rec=""; off=0
      while :; do
        page=$(wallet "$other" "/wallet/boxes?minConfirmations=0&limit=$WO_PAGE&offset=$off" | _wo_json array)
        [[ "$page" == null ]] && break
        rec=$(jq -c --arg id "$id" 'map(select(.box.boxId == $id))[0] // empty | {spent, spendingTransaction, spendingHeight, inclusionHeight, onchain, scans}' <<< "$page")
        k=$(jq length <<< "$page"); [[ -n "$rec" || "$k" -lt "$WO_PAGE" ]] && break; off=$((off + k))
      done
      echo "[wallet-oracle]   explain: box ${id:0:8} held only by the $side; $other's wallet: ${rec:-absent}; UTXO set: $s=$(rest "$s" "/utxo/byId/$id" | jq -r 'if .boxId then "yes" else "no" end' 2>/dev/null) $r=$(rest "$r" "/utxo/byId/$id" | jq -r 'if .boxId then "yes" else "no" end' 2>/dev/null)"
    done
  done; }

# wo_versions: one JSON object {node: appVersion} over the rig's NODES (the diffrun scenario wraps it into RESULT_JSON's
# "versions"; a node that does not answer reports "null")
wo_versions(){ local n vs='{}'
  for n in "${NODES[@]}"; do vs=$(jq -c --arg k "$n" --arg v "$(rest "$n" /info | jq -r '.appVersion // "null"' 2>/dev/null)" '. + {($k): $v}' <<< "$vs"); done
  echo "$vs"; }
