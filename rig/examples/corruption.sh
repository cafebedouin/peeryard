# corruption: what a node does after its data directory is damaged while it is down. A mines, B follows to a
# settled height. Then, for each injury in CORRUPTION_INJURIES (default: all four of rig.sh's `corrupt`): B is
# crashed (SIGKILL), the injury is applied to $SCRATCH/data_B only, B is revived and watched for
# CORRUPTION_WATCH_S seconds. Outcomes per injury: `refused` (the node exits or never serves REST), `recovered@h`
# (it comes up and reaches the same chain AND state root as A), `stuck@h` (up, but never agrees within the
# window), `DIFF@h` (up and serving a state root that differs from A's at an equal height). Between injuries B is
# wiped and resynced so each injury starts from a healthy node. These are honest failures (partial or torn
# writes, lost files), not crafted input.
#   PEERYARD_JAR=~/ergo-6.0.6.jar bash rig/rig.sh rig/examples/corruption.json rig/examples/corruption.sh
# PASS = no injury produced a DIFF outcome (a damaged node never served a state root that disagrees with the
# miner's at an equal height) and at least one injury was actually applied. refused / recovered / stuck are
# reported, not judged: the safety property is "never serve a wrong state"; liveness after damage is what the
# report describes. INCONCLUSIVE = no injury could be applied (every `corrupt` failed), so nothing was tested.
INJ=${CORRUPTION_INJURIES:-"truncate-state zero-state-log drop-undo drop-history-objects"}; WATCH=${CORRUPTION_WATCH_S:-120}   # CORRUPTION_SETTLE_MIN: height both nodes reach before the first injury (default 30)
settle(){ # settle <min height>: pause A's miner (a follower never sits level with a live 2 s miner), wait until B
  # is fully synced with A at height >= $1 with the same state root, resume mining. Runs in the main shell (a
  # subshell would leave the rig's process table stale after the restart); result in SETTLED_H (0 = never).
  local end st h; SETTLED_H=0
  end=$((SECONDS + 240 + 3 * $1)); while [ $SECONDS -lt $end ] && [ "$(full_height A)" -lt "$1" ]; do sleep 3; done   # let A mine to the target first
  stop_mining A >/dev/null; end=$((SECONDS + 180))
  while [ $SECONDS -lt $end ]; do st=$(same_state A B)
    case "$st" in SAME@*) h=${st#SAME@}; h=${h%%:*}; [ "${h:-0}" -ge "$1" ] && { SETTLED_H=$h; break; } ;; esac
    echo "    settle: A.full=$(full_height A) B.full=$(full_height B) same_state=${st%%:*}"; sleep 5; done
  start_mining A 500ms >/dev/null; [ "$SETTLED_H" != 0 ]; }
settle "${CORRUPTION_SETTLE_MIN:-30}" || { echo "[corruption] FAIL: B never settled with A"; rig_verdict=FAIL; return; }; h0=$SETTLED_H
echo "[corruption] baseline: A and B agree at height $h0; B data $(data_mb B) MB; state files: $(find "$SCRATCH/data_B/state/ldb_main" -type f | wc -l)"
declare -A OUT; anydiff=no; applied=0; uncompared=0
# root_at_leader NODE: B's current state root against the root in A's header at B's full height, when both are on the
# same chain there (a stuck node is still checked, even while A is ahead): prints SAME@h, DIFF@h or nothing
# B's height and root come from one /info response: two reads could straddle a block B applies in between and pair
# a root with the wrong height.
root_at_leader(){ local info hb rb ia ra; info=$(rest "$1" /info)
  hb=$(jq -r '.fullHeight // 0' <<< "$info"); rb=$(jq -r '.stateRoot // empty' <<< "$info"); [ "${hb:-0}" -ge 1 ] || return 0
  [ "$(same_chain A "$1" | cut -c1-4)" = SAME ] || return 0
  ia=$(header_at A "$hb")
  [ -n "$ia" ] && ra=$(rest A "/blocks/$ia/header" | jq -r '.stateRoot // empty')
  [ -n "$rb" ] && [ -n "${ra:-}" ] || return 0
  if [ "$rb" = "$ra" ]; then echo "SAME@$hb"; else echo "DIFF@$hb"; fi; }
for inj in $INJ; do
  echo "[corruption] --- injury: $inj ---"
  crash B; sleep 2
  corrupt B "$inj" || { OUT[$inj]="injury-failed"; continue; }
  applied=$((applied + 1))
  launch B
  if ! wait_up B; then
    OUT[$inj]="refused"; echo "[corruption] $inj: B did not come up (log tail):"; grep -v '^\s*at ' "$RIG_LOG_DIR/node_B.log" | tail -4 | cut -c1-160
  else
    # watch with A's miner paused, so equal heights are reachable and same_state can decide; a node that
    # exits during the watch is "refused"
    stop_mining A >/dev/null
    end=$((SECONDS + WATCH)); out=""; while [ $SECONDS -lt $end ]; do
      st=$(same_state A B); sc=$(same_chain A B)
      case "$st" in SAME@*) out="recovered@${st#SAME@}"; out=${out%%:*}; break ;; DIFF@*) out="DIFF@${st#DIFF@}"; out=${out%%:*}; anydiff=yes; break ;; esac
      case "$sc" in DIFF@*) out="DIFF-chain@${sc#DIFF@}"; out=${out%%:*}; anydiff=yes; break ;; esac
      kill -0 "${PID[B]}" 2>/dev/null || { out="refused"; break; }
      sleep 5; done
    if [ -z "$out" ]; then
      out="stuck@$(full_height B)/$(rest B /info | jq -r '.headersHeight // 0')"; rl=$(root_at_leader B)
      case "$rl" in SAME@*) out="$out root-same" ;; DIFF@*) out="DIFF-root@${rl#DIFF@}"; anydiff=yes ;;
        *) [ "$(full_height B)" -ge 1 ] 2>/dev/null && { out="$out uncompared"; uncompared=$((uncompared + 1)); } ;; esac
    fi
    start_mining A 500ms >/dev/null
    OUT[$inj]="$out"; echo "[corruption] $inj: $out (B.full=$(full_height B) A.full=$(full_height A) same_chain=$(same_chain A B | cut -c1-12))"
    grep -i -E 'corrupt|Corruption|exception|error' "$RIG_LOG_DIR/node_B.log" | grep -v '^\s*at ' | tail -3 | cut -c1-160 | sed 's/^/    log: /'
  fi
  # a healthy B for the next injury: wipe and resync
  crash B; sleep 1; wipe B; launch B; wait_up B >/dev/null || true; sleep 20
  settle $(( $(full_height A) - 2 )) >/dev/null || echo "[corruption] note: B did not resettle after $inj"
done
echo "[corruption] outcomes:"; for inj in $INJ; do echo "  $inj: ${OUT[$inj]:-?}"; done
res=PASS; [ $anydiff = yes ] && res=FAIL
[ $res = PASS ] && [ "$applied" = 0 ] && { res=INCONCLUSIVE; echo "[corruption] INCONCLUSIVE: no injury could be applied, so no damaged node was observed"; }
# a damaged node that served state which could not be compared with A's does not show the safety property
[ $res = PASS ] && [ "$applied" -gt 0 ] && [ "$uncompared" = "$applied" ] && { res=INCONCLUSIVE; rig_cause=NOTHING_COMPARED; echo "[corruption] INCONCLUSIVE: every damaged node served state that could not be compared with A's"; }
echo "[corruption] injuries applied: $applied of $(wc -w <<< "$INJ")"
echo "[corruption] === CORRUPTION: $res ($(for inj in $INJ; do printf '%s=%s ' "$inj" "${OUT[$inj]:-?}"; done)) ==="; rig_verdict=$res
echo "CORRUPTION-DONE"
