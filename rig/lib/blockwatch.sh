# rig/lib/blockwatch.sh: the per-block invariant monitor. Sourced by rig.sh.
#
#   blockwatch_start <node>...                    background collector, every BLOCKWATCH_POLL_S (2) s per node: each
#                                                 full block new on the node (and the BLOCKWATCH_DEPTH (6) heights below
#                                                 its tip, re-read so a reorg is seen) as GET /blocks/<id>, and after new
#                                                 blocks the node's unconfirmed pool, into $RIG_LOG_DIR/blocks.jsonl
#   blockwatch_stop [--contract <cmd>]...         stop it and check every block (diag/block_invariants.py: link, body,
#                                                 once, pool, agree, and each contract command); sets BLOCKWATCH_RESULT
#                                                 (OK, or VIOLATED total=<n> <check>=<n>...) and returns 1 on a violation
#
# Contract commands also come from BLOCKWATCH_CONTRACTS (several separated by ';'). The rig stops a monitor the hook
# left running, and a violation turns the hook's PASS into FAIL (cause BLOCK_INVARIANT; PEERYARD_BLOCKWATCH_JUDGE=0
# reports it only). It starts at the node's full height minus BLOCKWATCH_DEPTH when started, or at BLOCKWATCH_FROM.
# rig/lib/invariants/deliberate-fail.sh is a contract check that fails (on every block, or every
# DELIBERATE_FAIL_EVERY-th height): with it the monitor must report, which shows a violation reaches the verdict.
# Reads only: it asks the nodes' REST API for blocks and pools and never sends anything else.

BLOCKWATCH_PID=""; BLOCKWATCH_RESULT=""
_bw_loop(){ local nodes=("$@") x info full top from h id blk depth="${BLOCKWATCH_DEPTH:-6}" new; declare -A LASTF LASTTOP SEEN START
  for x in "${nodes[@]}"; do top=$(full_height "$x"); START[$x]=$(( ${BLOCKWATCH_FROM:-$(( top - depth ))} )); (( ${START[$x]} < 1 )) && START[$x]=1; done
  while :; do
    for x in "${nodes[@]}"; do
      info="$(rest "$x" /info 2>/dev/null)"; full="$(jq -r '"\(.fullHeight // "")/\(.bestFullHeaderId // "")"' <<< "$info" 2>/dev/null)"
      [[ "$full" =~ ^[0-9]+/[0-9a-f]{64}$ && "$full" != "${LASTF[$x]:-}" ]] || continue
      LASTF[$x]="$full"; top="${full%/*}"; new=0
      # from the height after the last tip read, and always the last BLOCKWATCH_DEPTH heights again (a reorg)
      from=$(( ${LASTTOP[$x]:-$(( ${START[$x]} - 1 ))} + 1 )); (( from > top - depth )) && from=$(( top - depth )); (( from < ${START[$x]} )) && from=${START[$x]}
      for ((h = from; h <= top; h++)); do
        id="$(header_at "$x" "$h")"; [[ "$id" =~ ^[0-9a-f]{64}$ ]] || continue
        [[ "${SEEN[$x/$h]:-}" == "$id" ]] && continue
        blk="$(rest "$x" "/blocks/$id")"; jq -e '.header.id' <<< "$blk" >/dev/null 2>&1 || continue
        SEEN[$x/$h]="$id"; new=1
        jq -c --argjson t "$(date +%s%3N)" --arg n "$x" --argjson h "$h" --arg id "$id" '{t_ms: $t, node: $n, h: $h, id: $id, block: .}' <<< "$blk"
      done
      LASTTOP[$x]=$top
      (( new )) && jq -cn --argjson t "$(date +%s%3N)" --arg n "$x" --argjson h "$top" --arg ids "$(mempool_ids "$x" | paste -sd, -)" \
        '{t_ms: $t, node: $n, ev: "pool", h: $h, ids: ($ids | if . == "" then [] else split(",") end)}'
    done
    sleep "${BLOCKWATCH_POLL_S:-2}"
  done; }
blockwatch_start(){ [[ $# -ge 1 ]] || { echo "[blockwatch] needs at least one node"; return 1; }
  [[ -z "$BLOCKWATCH_PID" ]] || { echo "[blockwatch] already running (pid $BLOCKWATCH_PID)"; return 1; }
  _bw_loop "$@" >> "$RIG_LOG_DIR/blocks.jsonl" 2>> "$RIG_LOG_DIR/blockwatch.err" & BLOCKWATCH_PID=$!; BG_PIDS+=("$BLOCKWATCH_PID")
  mark blockwatch-start; echo "[blockwatch] started on $* (every ${BLOCKWATCH_POLL_S:-2} s, depth ${BLOCKWATCH_DEPTH:-6}; pid $BLOCKWATCH_PID)"; }
blockwatch_stop(){ local args=() c out rc
  if [[ -n "$BLOCKWATCH_PID" ]]; then kill "$BLOCKWATCH_PID" 2>/dev/null; wait "$BLOCKWATCH_PID" 2>/dev/null; BLOCKWATCH_PID=""; mark blockwatch-stop; fi
  while [[ $# -gt 0 ]]; do case "$1" in --contract) args+=(--contract "$2"); shift 2 ;; *) echo "[blockwatch] blockwatch_stop: unknown argument $1"; return 2 ;; esac; done
  IFS=';' read -r -a c <<< "${BLOCKWATCH_CONTRACTS:-}"; for x in "${c[@]}"; do [[ -n "${x// /}" ]] && args+=(--contract "$x"); done
  out="$(python3 "$(dirname "${BASH_SOURCE[0]}")/../../diag/block_invariants.py" "$RIG_LOG_DIR/blocks.jsonl" --json "$RIG_LOG_DIR/invariants.json" "${args[@]}" 2>&1)"; rc=$?
  while IFS= read -r l; do echo "[blockwatch] $l"; done <<< "$out"
  case $rc in
    0) BLOCKWATCH_RESULT=OK ;;
    1) BLOCKWATCH_RESULT="$(sed -n 's/^INVARIANTS: //p' <<< "$out")" ;;
    *) BLOCKWATCH_RESULT="NO-INPUT"; echo "[blockwatch] nothing was checked (no block recorded); see $RIG_LOG_DIR/blockwatch.err" ;;
  esac
  [[ $rc == 0 ]]; }
