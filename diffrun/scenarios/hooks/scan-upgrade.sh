# shellcheck shell=bash
# scan-upgrade: wallet scans written by a released node (the writer, node A's topology jar SCANUP_WRITER_JAR), read
# after node A is stopped and started in place on this role's jar (PEERYARD_JAR) over the same data directory.
# One node, no peers; mining only while the hook asks for it.
#   writer   scan 11 tracks the emission contract (R1 equals its tree: one new box per block, the old one spent),
#            scan 12 the miner's reward script (one new unspent box per block); both with walletInteraction off.
#            The node mines until scan 11 has >= 10 spent boxes and scan 12 >= 10 unspent ones, then stops mining.
#            SCANUP_WRAP=1: before that, filler scans 13..32767 (a rule that matches nothing) are registered, then
#            two more scans with the reward rule, which a release whose counter is a Short numbers -32768 and
#            -32767; one confirmed reward box is added to both with /scan/addBox.
#   W        the writer's answers at a still height: /scan/listAll, and per scan /scan/unspentBoxes,
#            /scan/spentBoxes, /wallet/transactionsByScanId (negative ids: what the writer's routes answer).
#   swap     node A restarted on this role's jar (mining off), the same queries at the same height (R0).
#   R1       K more blocks mined on this role's jar, the same queries again; then one more scan is registered.
# Projections compared (W against R0): listAll {scanId, scanName, walletInteraction, removeOffchain, trackingRule}
# over the writer's scan ids; boxes {boxId, value, inclusionHeight, spendingHeight, spendingTransaction,
# creationTransaction, sorted scans, confirmationsNum}; transactions {id, inclusionHeight, sorted scans,
# numConfirmations}. Every answer and its HTTP status is kept under $SCRATCH/su-<W|R0|R1>/ and copied to the log dir.
# RESULT_JSON metrics:
#   writer_ok (the writer's scans got ids 11 and 12 and reached the box counts; with SCANUP_WRAP=1 also: the
#   counter wrapped to -32768 and addBox answered), alive (REST and the wallet came up on this role's jar),
#   eq_listall, eq_boxes, eq_txs (R0 equals W on that projection), tracks (after K blocks: scan 11 one unspent box
#   and as many more spent boxes as blocks were mined, scan 12 as many more unspent boxes), blocks_after,
#   next_id (the id this role's jar gives the next scan), next_code (HTTP status of that scan's unspentBoxes),
#   wrapped (the writer's counter reached -32768), neg_listed (listAll on this role's jar has -32768 and -32767),
#   neg_box_found (the added box is in unspentBoxes of both), neg_tracks (scan -32767 gains a box per block after
#   the swap), neg_box_code (HTTP status of /scan/unspentBoxes/-32767 on this role's jar, 0 when not asked),
#   fill_seconds (time to register the filler scans, -1 when none),
#   pass = writer_ok, alive, eq_listall, eq_boxes, eq_txs, tracks (and next_id 13 when SCANUP_WRAP=0),
#   wrapped_supported = neg_listed, neg_box_found, neg_tracks and next_id 32768 (SCANUP_WRAP=1 only, else false).
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SU_WRAP="${SCANUP_WRAP:-0}"; SU_K="${SCANUP_K:-5}"; SU_MIN="${SCANUP_MIN_BOXES:-10}"
su(){ echo "[scan-up] $*"; }
su_ver(){ rest A /info | jq -r '.appVersion // "null"'; }
su_get(){ ip netns exec "${NS[A]}" curl -s -o "$2" -w '%{http_code}' --max-time 90 -H "api_key: $API_KEY" "http://127.0.0.1:${REST[A]}$1"; }
su_ready(){ local s i; for i in $(seq 1 60); do s=$(wallet A /wallet/status 2>/dev/null)
    [[ "$(jq -r '.isInitialized // false' <<< "$s" 2>/dev/null)" == true && -z "$(jq -r '.error // empty' <<< "$s" 2>/dev/null)" ]] && return 0
    sleep 2; done; return 1; }
su_count(){ jq -r 'if type == "array" then length else -1 end' "$1" 2>/dev/null || echo -1; }
SU_PB='[.[] | {boxId: .box.boxId, value: .box.value, inclusionHeight, spendingHeight, spendingTransaction, creationTransaction, scans: (.scans | sort), confirmationsNum}] | sort_by(.boxId)'
SU_PT='[.[] | {id, inclusionHeight, scans: (.scans | sort), numConfirmations}] | sort_by(.id)'
SU_PL='[.[] | {scanId, scanName, walletInteraction, removeOffchain, trackingRule}] | sort_by(.scanId)'
# su_q <dir> <name> <path> <projection>: one GET, its status in code_<name>, the projected answer in <name>.json
# (the JSON string "HTTP <status>" when the status is not 200 or the body does not project)
su_q(){ local d="$1" n="$2" c
  c=$(su_get "$3" "$d/raw_$n"); echo "$c" > "$d/code_$n"
  if [[ "$c" == 200 ]] && jq -c "$4" "$d/raw_$n" > "$d/$n.json" 2>/dev/null; then :; else jq -cn --arg c "$c" '"HTTP " + $c' > "$d/$n.json"; fi; }
# su_snap <tag> <id>...: listAll and the three per-scan answers for every id
su_snap(){ local t="$1" d="$SCRATCH/su-$1" id; shift; mkdir -p "$d"
  full_height A > "$d/height"
  su_q "$d" listall /scan/listAll "$SU_PL"
  for id in "$@"; do
    su_q "$d" "u_$id" "/scan/unspentBoxes/$id?limit=2500" "$SU_PB"
    su_q "$d" "s_$id" "/scan/spentBoxes/$id?limit=2500" "$SU_PB"
    su_q "$d" "t_$id" "/wallet/transactionsByScanId/$id" "$SU_PT"
  done
  su "snapshot $t at height $(cat "$d/height"): listAll $(su_count "$d/listall.json") scans$(for id in "$@"; do printf ', %s u=%s s=%s t=%s' "$id" "$(su_count "$d/u_$id.json")" "$(su_count "$d/s_$id.json")" "$(su_count "$d/t_$id.json")"; done)"; }
su_same(){ if cmp -s "$1" "$2"; then return 0; fi
  su "DIFF $(basename "$1"): $(diff <(jq -S . "$1" 2>/dev/null) <(jq -S . "$2" 2>/dev/null) | head -12 | tr '\n' ' ' | cut -c1-600)"; return 1; }
su_reg(){ wallet A /scan/register "{\"scanName\":\"$1\",\"walletInteraction\":\"off\",\"removeOffchain\":true,\"trackingRule\":{\"predicate\":\"equals\",\"register\":\"R1\",\"value\":\"$2\"}}" | jq -r '.scanId // empty' 2>/dev/null; }
su_bool(){ [[ "$1" == true ]] && echo true || echo false; }
su_inconclusive(){ rig_verdict=INCONCLUSIVE; su "=== SCAN-UPGRADE: INCONCLUSIVE ($1) ==="; }

scan_upgrade(){
  local reader writer vW vR em emv rw rwv id11 id12 i end W R0 R1 fill fill_s=-1 wrapped=false nid1 nid2 added=""
  local writer_ok=false alive=false eq_l=true eq_b=true eq_t=true tracks=false nb=0 next_id=-1 next_code=0
  local neg_listed=false neg_found=false neg_tracks=false neg_code=0 ids pass wsup h0 h1 hs c
  reader="$(readlink -f "${PEERYARD_JAR:-}")"; writer="$(readlink -f "${NODE_JAR[A]}")"
  [[ -f "$reader" && -f "$writer" ]] || { su_inconclusive "needs the writer jar (topology) and this role's jar (PEERYARD_JAR)"; return; }
  su "writer $(basename "$writer") ($(sha256sum "$writer" | cut -c1-16)), reader $(basename "$reader") ($(sha256sum "$reader" | cut -c1-16)), wrap=$SU_WRAP"
  su_ready || { su_inconclusive "the writer's wallet never reported initialized"; return; }
  vW=$(su_ver)

  # 1. writer: mining on (the reward address needs the miner), the two scans, the filler scans when asked
  start_mining A > /dev/null
  end=$((SECONDS + 120)); while [[ $SECONDS -lt $end && "$(full_height A)" -lt 2 ]]; do sleep 2; done
  em=$(rest A /emission/scripts | jq -r '.emission // empty'); emv=$([[ -n "$em" ]] && rest A "/script/addressToBytes/$em" | jq -r '.bytes // empty')
  rw=$(wallet A /mining/rewardAddress | jq -r '.rewardAddress // empty'); rwv=$([[ -n "$rw" ]] && rest A "/script/addressToBytes/$rw" | jq -r '.bytes // empty')
  [[ -n "$emv" && -n "$rwv" ]] || { su_inconclusive "no emission or reward script (emission=${em:0:20} reward=${rw:0:20})"; return; }
  id11=$(su_reg su-emission "$emv"); id12=$(su_reg su-reward "$rwv")
  su "writer $vW: scans $id11 (emission $em) and $id12 (reward $rw)"
  if [[ "$SU_WRAP" == 1 ]]; then
    stop_mining A > /dev/null
    fill=$(ip netns exec "${NS[A]}" python3 -I "$here/scan-upgrade-fill.py" 127.0.0.1 "${REST[A]}" "$API_KEY" $((32767 - 12)) 2> "$SCRATCH/fill.err")
    su "filler scans: $fill"
    fill_s=$(jq -r '.seconds // -1' <<< "$fill" 2>/dev/null); [[ "$fill_s" =~ ^[0-9.]+$ ]] || fill_s=-1
    nid1=$(su_reg su-wrap-a "$rwv"); nid2=$(su_reg su-wrap-b "$rwv")
    su "after the fillers: next two scans got ids $nid1 and $nid2"
    [[ "$nid1" == -32768 && "$nid2" == -32767 ]] && wrapped=true
    start_mining A > /dev/null
  fi
  end=$((SECONDS + 420))
  while [[ $SECONDS -lt $end ]]; do
    su_get "/scan/spentBoxes/$id11?limit=2500" "$SCRATCH/c11" > /dev/null; su_get "/scan/unspentBoxes/$id12?limit=2500" "$SCRATCH/c12" > /dev/null
    [[ "$(su_count "$SCRATCH/c11")" -ge "$SU_MIN" && "$(su_count "$SCRATCH/c12")" -ge "$SU_MIN" ]] && break; sleep 3
  done
  if [[ "$SU_WRAP" == 1 && $wrapped == true ]]; then
    local box; box=$(jq -c '[.[] | select(.inclusionHeight != null)] | sort_by(.inclusionHeight) | .[0].box // empty' "$SCRATCH/c12" 2>/dev/null)
    [[ -n "$box" ]] && added=$(wallet A /scan/addBox "{\"scanIds\":[-32768,-32767],\"box\":$box}" | jq -r 'if type == "string" then . else empty end' 2>/dev/null)
    su "addBox to -32768 and -32767: ${added:-failed}"
  fi
  stop_mining A > /dev/null
  hs=$(full_height A); sleep 10; [[ "$(full_height A)" == "$hs" ]] || { su_inconclusive "height moved after mining stopped ($hs -> $(full_height A))"; return; }
  [[ "$id11" == 11 && "$id12" == 12 && "$(su_count "$SCRATCH/c11")" -ge "$SU_MIN" && "$(su_count "$SCRATCH/c12")" -ge "$SU_MIN" ]] && writer_ok=true
  [[ "$SU_WRAP" == 1 ]] && { [[ $wrapped == true && "$added" =~ ^[0-9a-f]{64}$ ]] || writer_ok=false; }
  ids=("$id11" "$id12"); [[ "$SU_WRAP" == 1 ]] && ids+=(-32768 -32767)
  su_snap W "${ids[@]}"; W="$SCRATCH/su-W"

  # 2. swap: the same data directory on this role's jar
  NODE_JAR[A]="$reader"
  [[ -n "${RUNTIME_CWD:-}" ]] || unzip -o -q "$reader" application.conf devnet.conf mainnet.conf testnet.conf -d "${RT_CWD[A]}/src/main/resources"
  mark scan-upgrade-swap
  if relaunch A && su_ready; then alive=true; fi
  vR=$(su_ver); su "after the swap: appVersion $vR, alive $alive, height $(full_height A)"
  if [[ $alive == true ]]; then
    su_snap R0 "${ids[@]}"; R0="$SCRATCH/su-R0"
    [[ "$(cat "$R0/height")" == "$(cat "$W/height")" ]] || su "WARN height $(cat "$W/height") at W, $(cat "$R0/height") at R0"
    jq -c --slurpfile w "$W/listall.json" '($w[0] | if type == "array" then map({key: (.scanId | tostring), value: true}) | from_entries else {} end) as $s
      | if type == "array" then [.[] | select($s[.scanId | tostring])] else . end' "$R0/listall.json" > "$R0/listall_w.json"
    su_same "$W/listall.json" "$R0/listall_w.json" || eq_l=false
    for i in "$id11" "$id12"; do su_same "$W/u_$i.json" "$R0/u_$i.json" || eq_b=false; su_same "$W/s_$i.json" "$R0/s_$i.json" || eq_b=false; done
    for i in "${ids[@]}"; do su_same "$W/t_$i.json" "$R0/t_$i.json" || eq_t=false; done
    if [[ "$SU_WRAP" == 1 ]]; then
      [[ "$(jq -r '[.[]? | .scanId] | (index(-32768) != null and index(-32767) != null)' "$R0/listall.json" 2>/dev/null)" == true ]] && neg_listed=true
      [[ -n "$added" && "$(jq -r --arg b "$added" '[(.[]? | .boxId)] | index($b) != null' "$R0/u_-32768.json" 2>/dev/null)" == true \
         && "$(jq -r --arg b "$added" '[(.[]? | .boxId)] | index($b) != null' "$R0/u_-32767.json" 2>/dev/null)" == true ]] && neg_found=true
      neg_code=$(cat "$R0/code_u_-32767")
    fi
    # 3. K more blocks on this role's jar
    h0=$(full_height A); mine A "$SU_K" > /dev/null; h1=$(full_height A); nb=$((h1 - h0))
    su_snap R1 "${ids[@]}"; R1="$SCRATCH/su-R1"
    [[ $nb -ge 1 && "$(su_count "$R1/u_$id11.json")" == 1 \
       && $(( $(su_count "$R1/s_$id11.json") - $(su_count "$R0/s_$id11.json") )) == "$nb" \
       && $(( $(su_count "$R1/u_$id12.json") - $(su_count "$R0/u_$id12.json") )) == "$nb" ]] && tracks=true
    if [[ "$SU_WRAP" == 1 ]]; then
      c=$(su_count "$R0/u_-32767.json"); [[ "$c" -ge 0 && $(( $(su_count "$R1/u_-32767.json") - c )) -ge "$nb" && $nb -ge 1 ]] && neg_tracks=true
    fi
    next_id=$(su_reg su-next "$rwv"); [[ "$next_id" =~ ^-?[0-9]+$ ]] || next_id=-1
    next_code=$(su_get "/scan/unspentBoxes/$next_id?limit=10" "$SCRATCH/next.json")
    su "next scan id $next_id (unspentBoxes HTTP $next_code)"
  else
    # no REST on this role's jar: the version is the jar's own (application.conf), so the run is still classified
    vR=$(unzip -p "$reader" application.conf 2>/dev/null | sed -n 's/^ *appVersion *= *//p' | head -1)
    su "this role's jar did not come up; its application.conf says appVersion $vR"
    eq_l=false; eq_b=false; eq_t=false
  fi
  cp -r "$SCRATCH"/su-* "$RIG_LOG_DIR/" 2>/dev/null

  pass=false
  [[ $writer_ok == true && $alive == true && $eq_l == true && $eq_b == true && $eq_t == true && $tracks == true ]] && pass=true
  [[ "$SU_WRAP" == 1 || "$next_id" == 13 ]] || pass=false
  wsup=false; [[ "$SU_WRAP" == 1 && $neg_listed == true && $neg_found == true && $neg_tracks == true && "$next_id" == 32768 ]] && wsup=true
  rig_verdict=$([[ $pass == true ]] && echo PASS || echo FAIL)
  echo "RESULT_JSON $(jq -cn --arg v "${vR:-null}" --arg wv "$vW" --arg wt "${SCANUP_WRITER_TAG:-}" \
    --arg jv "$(${PEERYARD_JAVA:-java} -version 2>&1 | head -1)" \
    --argjson wo "$(su_bool $writer_ok)" --argjson al "$(su_bool $alive)" --argjson el "$(su_bool $eq_l)" \
    --argjson eb "$(su_bool $eq_b)" --argjson et "$(su_bool $eq_t)" --argjson tr "$(su_bool $tracks)" --argjson nb "$nb" \
    --argjson ni "$next_id" --argjson nc "${next_code:-0}" --argjson wr "$(su_bool $wrapped)" --argjson nl "$(su_bool $neg_listed)" \
    --argjson nf "$(su_bool $neg_found)" --argjson nt "$(su_bool $neg_tracks)" --argjson ncd "${neg_code:-0}" \
    --argjson fs "$fill_s" --argjson p "$(su_bool $pass)" --argjson ws "$(su_bool $wsup)" \
    '{schema_version:1, scenario:(if env.SCANUP_WRAP == "1" then "scan-upgrade-wrap" else "scan-upgrade" end),
      runtime:{java:$jv, writer_tag:$wt, writer_version:$wv}, versions:{A:$v},
      metrics:{writer_ok:$wo, alive:$al, eq_listall:$el, eq_boxes:$eb, eq_txs:$et, tracks:$tr, blocks_after:$nb,
        next_id:$ni, next_code:$nc, wrapped:$wr, neg_listed:$nl, neg_box_found:$nf, neg_tracks:$nt, neg_box_code:$ncd,
        fill_seconds:$fs, pass:$p, wrapped_supported:$ws}}')"
  su "=== SCAN-UPGRADE: $rig_verdict (writer $vW -> $vR; writer_ok $writer_ok alive $alive listAll $eq_l boxes $eq_b txs $eq_t tracks $tracks next $next_id; wrapped $wrapped listed $neg_listed found $neg_found tracks $neg_tracks) ==="
}
scan_upgrade
