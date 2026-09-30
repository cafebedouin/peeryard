# rig/lib/faults.sh: fault injection on stopped node data directories (corrupt, wipe).
# Sourced by rig.sh; scenario hooks may rely on hook_api.sh functions.
# ---- fault injection on a stopped node's data directory (honest failures: partial writes, lost files) ----
# corrupt <node> <injury>: the node must be down (crash <node> first). Injuries:
#   truncate-state      cut the newest file of the UTXO state store (state/ldb_main) to half its size (a partial
#                       write at power loss)
#   zero-state-log      overwrite the newest state-store file with zeros of the same size (a torn write)
#   drop-undo           delete state/ldb_undo (the rollback data)
#   drop-history-objects  delete history/objects but keep history/index (an index pointing at nothing)
# Prints what it did. Touches only $SCRATCH/data_<node>.
corrupt(){ local n="$1" inj="$2"; local d="$SCRATCH/data_$n" f sz
  [[ -z "${PID[$n]:-}" ]] || { echo "[corrupt] $n is running; crash it first" >&2; return 1; }
  [[ -d "$d" ]] || { echo "[corrupt] no data dir $d" >&2; return 1; }
  case "$inj" in
    truncate-state|zero-state-log)
      f="$(find "$d/state/ldb_main" -type f -printf '%T@ %s %p\n' 2>/dev/null | sort -n | tail -1)"
      sz="$(cut -d' ' -f2 <<< "$f")"; f="$(cut -d' ' -f3- <<< "$f")"
      [[ -n "$f" && "${sz:-0}" -gt 0 ]] || { echo "[corrupt] no state file found under $d/state/ldb_main" >&2; return 1; }
      if [[ "$inj" == truncate-state ]]; then truncate -s $((sz / 2)) "$f"; echo "[corrupt] $n: truncated $(basename "$f") $sz -> $((sz / 2)) bytes"
      else dd if=/dev/zero of="$f" bs="$sz" count=1 conv=notrunc status=none; echo "[corrupt] $n: zeroed $(basename "$f") ($sz bytes)"; fi ;;
    drop-undo) rm -rf "$d/state/ldb_undo"; echo "[corrupt] $n: removed state/ldb_undo" ;;
    drop-history-objects) rm -rf "$d/history/objects"; echo "[corrupt] $n: removed history/objects (index kept)" ;;
    *) echo "[corrupt] unknown injury '$inj'" >&2; return 1 ;;
  esac; }
# wipe <node>: delete a stopped node's data directory (the next launch resyncs from scratch)
wipe(){ local n="$1"; [[ -z "${PID[$n]:-}" ]] || { echo "[wipe] $n is running; crash it first" >&2; return 1; }
  rm -rf "$SCRATCH/data_$n"; echo "[rig] wiped data of $n"; }
