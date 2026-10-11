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
    why=$(jq -nr --argjson is "$is" --argjson ir "$ir" --arg ws "$ws" --arg wr "$wr" --arg ps "$ps" --arg pr "$pr" '
      if ($is.fullHeight // 0) < 1 or ($ir.fullHeight // 0) < 1 then "no full block on one node"
      elif $is.bestFullHeaderId != $ir.bestFullHeaderId then "best full blocks differ (\($is.fullHeight), \($ir.fullHeight))"
      elif $ws != ($is.fullHeight | tostring) or $wr != ($ir.fullHeight | tostring) then "wallet heights \($ws), \($wr) at full height \($is.fullHeight)"
      elif $ps != $pr then "mempools differ"
      else "" end' 2>/dev/null || echo "unreadable")
    [[ -z "$why" ]] && { echo "SETTLED@$(jq -r .fullHeight <<< "$is")"; return 0; }
    [[ $SECONDS -ge $end ]] && { echo "NOT-SETTLED: $why"; return 1; }
    sleep 3
  done; }

# The comparison itself: a pure function of two snapshot files.
wallet_cmp(){ local res kind
  res=$(jq -n --slurpfile S "$1" --slurpfile R "$2" '
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
      elif $s.mempool != $r.mempool then "mempools differ: subject=\($s.mempool | length) reference=\($r.mempool | length) transactions"
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
  case $rc in 0) WO_RESULT=SAME ;; 1) WO_RESULT=DIFF ;; *) WO_RESULT=INCONCLUSIVE ;; esac
  return $rc; }
