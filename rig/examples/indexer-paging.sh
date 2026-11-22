# shellcheck shell=bash
# indexer-paging: does /blockchain/box/unspent/byAddress page confirmed and mempool boxes as one sequence?
# Topology indexer-diff.json: M mines (no indexer); X on PEERYARD_JAR and Y on PEERYARD_JAR_B follow M, both with
# extraIndex. Written for ergoplatform/ergo#2538 (Segment.retrieveUtxos applies offset/limit after combining
# confirmed and unconfirmed boxes).
# Steps:
#   content   M's rewards mature; M pays X's first address AX five times; every pool empties (all confirmed).
#   mempool   M stops mining; M pays AX three more times; wait until X's and Y's mempools hold the same 3+ txs.
#   read      settle (M, X, Y on one best full block, X's and Y's indexedHeight == full height, X and Y with one mempool
#             tx id set); on X and on Y, for sortDirection asc/desc x includeUnconfirmed true/false: the one-page listing
#             (offset 0, limit 100), then pages of limit L = 1, 2, 3 at offsets 0, L, 2L, ... while offset < N + L
#             (N = the one-page listing's length); the settle record is read again after the queries and must not move.
# Checks, per node and (direction, unconfirmed, L): P1 every page has at most L boxes; P2 the concatenated pages equal
# the one-page listing (ids, in order) with no id twice; P4 (with unconfirmed) the listing's mempool boxes are in the
# node's own pool order (/transactions/unconfirmed, outputs to AX). Across nodes: P3' the confirmed part of the one-page
# listings is equal in order and the mempool part is the same set at the same positions (the two pools may order the
# same transactions differently). Setup: with includeUnconfirmed=true each one-page listing holds every mempool output to AX
# (found by AX's ergoTree in /transactions/unconfirmed), with false none of them; else INCONCLUSIVE.
# Lines: `[indexer-paging] PAGING <node> <dir> unconf=<b> L=<n> P1=ok|FAIL P2=ok|FAIL pages=<sizes>`,
# `[indexer-paging] LISTING <dir> unconf=<b> P3=SAME|DIFF ...`. Node verdict: a node passes when P1 and P2 hold
# everywhere. RESULT_JSON carries x_paging_ok, y_paging_ok, x/y_confirmed_only_ok, listings_same. Honest nodes,
# ordinary payments only.
here_pg="$(dirname "$(readlink -f "$HOOK")")"
# shellcheck source=rig/lib/indexer.sh
source "$here_pg/../lib/indexer.sh"
OUT="$RIG_LOG_DIR/paging"; mkdir -p "$OUT"
ERG=1000000000
say(){ echo "[indexer-paging] $*"; }
inconclusive(){ say "INCONCLUSIVE: $1"; rig_verdict=INCONCLUSIVE; rig_cause=${2:-}; echo "[indexer-paging] === INDEXER-PAGING: INCONCLUSIVE ==="; }
wait_h(){ local n="$1" min="$2" end=$((SECONDS + ${3:-90})); while [ $SECONDS -lt $end ]; do [ "$(full_height "$n")" -ge "$min" ] 2>/dev/null && return 0; sleep 2; done; return 1; }
pool_ids(){ rest "$1" "/transactions/unconfirmed?limit=10000" | jq -c '[.[].id] | sort' 2>/dev/null || echo null; }
pool_empty(){ local n; for n in M X Y; do [ "$(mempool_size "$n")" = 0 ] || return 1; done; }
# settle record: heights, best id, indexed height and mempool ids of X and Y
settle_rec(){ local n f h i id; for n in X Y; do read -r f h i id <<< "$(idx_heights "$n")"; printf '%s=%s/%s/%s/%s/%s ' "$n" "$f" "$h" "$i" "$id" "$(pool_ids "$n")"; done; }
settled(){ local n f h i id ids=""; for n in M X Y; do read -r f h i id <<< "$(idx_heights "$n")"
    [[ "$f" =~ ^[0-9]+$ && "$f" -ge 1 && "$f" == "$h" ]] || return 1; [[ $n == M || "$i" == "$f" ]] || return 1; ids+="$id "; done
  [[ $(tr ' ' '\n' <<< "$ids" | grep -v '^$' | sort -u | wc -l) == 1 ]] || return 1
  [[ "$(pool_ids X)" == "$(pool_ids Y)" ]]; }
# listing <node> <dir> <unconf> <offset> <limit>: the box ids served, as a JSON array (or {"status":..})
listing(){ ip netns exec "${NS[$1]}" curl -s --max-time 15 \
    "http://127.0.0.1:${REST[$1]}/blockchain/box/unspent/byAddress/$AX?offset=$4&limit=$5&sortDirection=$2&includeUnconfirmed=$3" \
  | jq -c 'if type == "array" then [.[].boxId] else {status: (.error // .reason // tojson)} end' 2>/dev/null || echo '{"status":"no json"}'; }

VX=$(rest X /info | jq -r '.appVersion // "null"'); VY=$(rest Y /info | jq -r '.appVersion // "null"')
say "X=$VX ($(basename "${NODE_JAR[X]}")) Y=$VY ($(basename "${NODE_JAR[Y]}"))"
for n in X Y; do end=$((SECONDS + 90)); ih=""
  while [[ $SECONDS -lt $end ]]; do ih=$(rest "$n" /blockchain/indexedHeight | jq -r '.indexedHeight // empty' 2>/dev/null); [[ "$ih" =~ ^[0-9]+$ ]] && break; sleep 3; done
  [[ "$ih" =~ ^[0-9]+$ ]] || { inconclusive "$n serves no /blockchain/indexedHeight after 90 s" SETUP_NODE_API; return 0; }; done
AX=$(address X); [[ -n "$AX" ]] || { inconclusive "X has no wallet address" SETUP_NODE_API; return 0; }

# ---- content: five confirmed boxes at AX
wait_balance M $((50 * ERG)) 300 >/dev/null || { inconclusive "M never had 50 ERG spendable (height $(full_height M))" SETUP_SYNC; return 0; }
acc=0; for i in 1 2 3 4 5; do r=$(pay M X $((i * ERG))); [[ "$r" =~ ^[0-9a-f]{64}$ ]] && acc=$((acc + 1)) || say "M->X $i: $r"; sleep 0.5; done
end=$((SECONDS + 180)); while [[ $SECONDS -lt $end ]] && ! pool_empty; do sleep 3; done
h=$(full_height M); wait_h X $((h + 1)) 60; wait_h Y $((h + 1)) 60
say "content: $acc of 5 confirmed payments accepted; pools empty: $(pool_empty && echo yes || echo no); M at $(full_height M)"
[[ $acc == 5 ]] && pool_empty || { inconclusive "content not confirmed ($acc of 5 accepted)" SETUP_SYNC; return 0; }

# ---- mempool: three unconfirmed boxes at AX
# Pausing M takes a relaunch. Seen on the merge base with either jar: a follower that holds headers it never fetched
# bodies for (full height below header height) and stays so while no new block arrives, after a relaunch of M while
# it mined at 1 s. So M first mines slowly (SETTLE_POLL, 20 s) until X and Y are settled with it, then stops right after
# a settled check; if the network is not settled after the stop, this is tried once more (the rig's settle_follow).
pause_settled(){ local try
  for try in 1 2; do
    start_mining M "${SETTLE_POLL:-20s}" >/dev/null; relink 90 M >/dev/null
    end=$((SECONDS + 150)); while [[ $SECONDS -lt $end ]] && ! settled; do sleep 3; done
    stop_mining M >/dev/null; relink 90 M >/dev/null
    end=$((SECONDS + 60)); while [[ $SECONDS -lt $end ]] && ! settled; do sleep 3; done
    PAUSE_TRIES=$try
    say "pause try $try: peers of M: $(peers_of M | tr '\n' ' '); $(settle_rec | sed -E 's/([0-9a-f]{12})[0-9a-f]{52}/\1/g')"
    settled && return 0
  done; return 1; }
PAUSE_TRIES=0
pause_settled || { inconclusive "not settled after pausing M twice ($(settle_rec | sed -E 's/([0-9a-f]{12})[0-9a-f]{52}/\1/g'))" SETUP_SYNC; return 0; }
acc=0; for i in 1 2 3; do r=$(pay M X $(((10 + i) * ERG))); [[ "$r" =~ ^[0-9a-f]{64}$ ]] && acc=$((acc + 1)) || say "mempool M->X $i: $r"; sleep 1; done
end=$((SECONDS + 120)); while [[ $SECONDS -lt $end ]]; do
  [[ "$(mempool_size X)" -ge 3 && "$(mempool_size Y)" -ge 3 ]] && settled && break; sleep 3; done
settled || { inconclusive "not settled with the mempool txs on X and Y ($(settle_rec))" SETUP_SYNC; return 0; }
TREE=$(ip netns exec "${NS[X]}" curl -s --max-time 15 "http://127.0.0.1:${REST[X]}/blockchain/box/unspent/byAddress/$AX?limit=1" | jq -r '.[0].ergoTree // empty')
UNC=$(rest X "/transactions/unconfirmed?limit=10000" | jq -c --arg t "$TREE" '[.[].outputs[] | select(.ergoTree == $t) | .boxId] | sort')
say "mempool: $acc of 3 unconfirmed payments accepted; $(jq length <<< "$UNC") mempool outputs to AX; settle $(settle_rec | cut -c1-200)"
[[ -n "$TREE" && "$(jq length <<< "$UNC")" -ge 3 ]] || { inconclusive "fewer than 3 mempool outputs to AX ($UNC)" SETUP_SYNC; return 0; }

# ---- read
# pool_order <node>: the node's mempool outputs to AX, in /transactions/unconfirmed order (the pool's own order)
pool_order(){ rest "$1" "/transactions/unconfirmed?limit=10000" | jq -c --arg t "$TREE" '[.[].outputs[] | select(.ergoTree == $t) | .boxId]' 2>/dev/null || echo null; }
before="$(settle_rec)"; declare -A PORD=( [X]="$(pool_order X)" [Y]="$(pool_order Y)" )
say "pool order (outputs to AX): X=$(jq -c 'map(.[0:12])' <<< "${PORD[X]}") Y=$(jq -c 'map(.[0:12])' <<< "${PORD[Y]}")"
declare -A OK=( [X]=true [Y]=true ) CONF_OK=( [X]=true [Y]=true ) ORD_OK=( [X]=true [Y]=true )
setup_ok=true; same=true
for dir in asc desc; do for unc in true false; do
  for n in X Y; do
    full="$(listing "$n" "$dir" "$unc" 0 100)"; echo "$full" > "$OUT/$n-$dir-$unc-full.json"
    jq -e 'type == "array"' <<< "$full" >/dev/null || { setup_ok=false; say "LISTING $n $dir unconf=$unc not a list: $full"; continue; }
    hit=$(jq -n --argjson f "$full" --argjson u "$UNC" '[$f[] | select(. as $i | $u | index($i))] | length')
    want=$([[ $unc == true ]] && jq length <<< "$UNC" || echo 0)
    [[ "$hit" == "$want" ]] || { setup_ok=false; say "SETUP $n $dir unconf=$unc holds $hit of the mempool outputs, expected $want"; }
    N=$(jq length <<< "$full")
    # P4: the mempool part of the listing, in order, is the node's own pool order (only with unconfirmed boxes)
    if [[ $unc == true ]]; then mp=$(jq -c --argjson u "$UNC" '[.[] | select(. as $i | $u | index($i))]' <<< "$full")
      [[ "$mp" == "${PORD[$n]}" ]] && p4=ok || { p4=FAIL; ORD_OK[$n]=false; }
      say "ORDER $n $dir P4=$p4 listing=$(jq -c 'map(.[0:12])' <<< "$mp") pool=$(jq -c 'map(.[0:12])' <<< "${PORD[$n]}")"; fi
    say "LISTING $n $dir unconf=$unc N=$N mempool-positions=$(jq -nc --argjson f "$full" --argjson u "$UNC" '[$f | to_entries[] | select(.value as $i | $u | index($i)) | .key]')"
    for L in 1 2 3; do
      pages='[]'; for ((off = 0; off < N + L; off += L)); do p="$(listing "$n" "$dir" "$unc" "$off" "$L")"
        jq -e 'type == "array"' <<< "$p" >/dev/null || p='["<error>"]'; pages=$(jq -c --argjson p "$p" '. + [$p]' <<< "$pages"); done
      echo "$pages" > "$OUT/$n-$dir-$unc-L$L-pages.json"
      p1=$(jq -r --argjson L "$L" 'if all(.[]; length <= $L) then "ok" else "FAIL" end' <<< "$pages")
      p2=$(jq -r --argjson f "$full" '(add // []) as $c | if ($c == $f and ($c | length) == ($c | unique | length)) then "ok" else "FAIL" end' <<< "$pages")
      say "PAGING $n $dir unconf=$unc L=$L P1=$p1 P2=$p2 pages=$(jq -c 'map(length)' <<< "$pages") concat=$(jq -c 'add // [] | length' <<< "$pages") distinct=$(jq -c 'add // [] | unique | length' <<< "$pages")"
      if [[ $p1 != ok || $p2 != ok ]]; then OK[$n]=false; [[ $unc == false ]] && CONF_OK[$n]=false; fi
    done
  done
  # P3': confirmed part equal in order; mempool part the same set at the same positions (each node keeps its own pool order)
  p3=$(jq -n -r --slurpfile x "$OUT/X-$dir-$unc-full.json" --slurpfile y "$OUT/Y-$dir-$unc-full.json" --argjson u "$UNC" '
    def conf: [.[] | select(. as $i | $u | index($i) | not)]; def pos: [to_entries[] | select(.value as $i | $u | index($i)) | .key];
    def mem: [.[] | select(. as $i | $u | index($i))] | sort;
    if ($x[0] | type) != "array" or ($y[0] | type) != "array" then "DIFF"
    elif ($x[0] | conf) == ($y[0] | conf) and ($x[0] | pos) == ($y[0] | pos) and ($x[0] | mem) == ($y[0] | mem) then "SAME" else "DIFF" end')
  exact=$(cmp -s "$OUT/X-$dir-$unc-full.json" "$OUT/Y-$dir-$unc-full.json" && echo yes || echo no)
  if [[ $p3 == SAME ]]; then say "LISTING $dir unconf=$unc P3'=SAME (byte-identical: $exact)"
  else same=false; say "LISTING $dir unconf=$unc P3'=DIFF x=$(head -c 300 "$OUT/X-$dir-$unc-full.json") y=$(head -c 300 "$OUT/Y-$dir-$unc-full.json")"; fi
done; done
after="$(settle_rec)"
[[ "${PORD[X]}" == "$(pool_order X)" && "${PORD[Y]}" == "$(pool_order Y)" ]] || { inconclusive "a pool order moved during the reads" SETUP_SYNC; return 0; }
[[ "$before" == "$after" ]] || { inconclusive "moved during the reads: before $before after $after" SETUP_SYNC; return 0; }
$setup_ok || { inconclusive "a one-page listing did not hold the expected mempool outputs" SETUP_SYNC; return 0; }

say "verdict: X paging ok ${OK[X]} (confirmed-only ok ${CONF_OK[X]}, pool order ok ${ORD_OK[X]}); Y paging ok ${OK[Y]} (confirmed-only ok ${CONF_OK[Y]}, pool order ok ${ORD_OK[Y]}); listings same $same"
if [[ ${OK[X]} == true && ${OK[Y]} == true && $same == true && ${ORD_OK[X]} == true && ${ORD_OK[Y]} == true ]]; then rig_verdict=PASS; else rig_verdict=FAIL; fi
echo "RESULT_JSON $(jq -cn --arg X "$VX" --arg Y "$VY" --argjson xo "${OK[X]}" --argjson yo "${OK[Y]}" --argjson xc "${CONF_OK[X]}" --argjson yc "${CONF_OK[Y]}" \
  --argjson s "$same" --argjson u "$(jq length <<< "$UNC")" --argjson fr "$PAUSE_TRIES" --argjson xr "${ORD_OK[X]}" --argjson yr "${ORD_OK[Y]}" --arg jv "$(${PEERYARD_JAVA:-java} -version 2>&1 | head -1)" \
  '{schema_version: 1, scenario: "indexer-paging", runtime: {java: $jv}, versions: {X: $X, Y: $Y},
    metrics: {x_paging_ok: $xo, y_paging_ok: $yo, x_confirmed_only_ok: $xc, y_confirmed_only_ok: $yc, listings_same: $s,
              x_pool_order_ok: $xr, y_pool_order_ok: $yr,
              x_pass: ($xo and $s and $xr), mempool_outputs: $u, pause_tries: $fr}}')"
echo "[indexer-paging] === INDEXER-PAGING: $rig_verdict ==="
