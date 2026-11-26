# rig/lib/bg.sh: the one registry of background helpers, walked by stop_all (rig.sh). Sourced by rig.sh before any
# helper can start.
#
# Every background process the rig or a hook starts beside the nodes is registered here with a label: the genesis
# probe, solver loops, the diag sampler, the health watcher, wire captures, the blockwatch collector, rent bots,
# companions, and a hook's own samplers. stop_all stops every one still registered before its final `wait`, which would
# otherwise wait for ever on a helper nobody stopped; a background job of the rig's shell that was never registered is
# then named, killed and counted (BG_UNREGISTERED), so that `wait` cannot hang on it either.
#
#   bg_register <pid> <label> [stop command...]   record a helper. With a stop command (a function and its words, run
#                                                 as given), stop_all runs that command after the nodes are stopped
#                                                 (a helper with its own graceful stop: wire captures, companions);
#                                                 without one, stop_all sends TERM before the nodes are stopped, waits
#                                                 up to BG_STOP_GRACE_S (5) s, then KILL.
#   bg_unregister <pid>                           a helper its owner stopped (or that ended) leaves the registry
#   bg_stop_all plain|own                         stop_all's two walks: the helpers without a stop command, or those with
#   bg_sweep <pid>...                             the unregistered jobs of this shell still running, the given pids
#                                                 (the nodes) excepted: each is named and killed
# BG_PIDS is the registry's list, in start order; a hook may still append a pid to it directly (label "hook").
BG_PIDS=(); declare -A BG_LABEL=() BG_STOP=(); BG_UNREGISTERED=0
bg_register(){ local p="$1" l="$2"; shift 2; BG_PIDS+=("$p"); BG_LABEL[$p]="$l"; BG_STOP[$p]="$*"; }
bg_unregister(){ local p keep=()
  for p in "${BG_PIDS[@]}"; do [[ "$p" == "$1" ]] || keep+=("$p"); done
  BG_PIDS=("${keep[@]}"); unset 'BG_LABEL[$1]' 'BG_STOP[$1]'; }
# _bg_child <pid>: the process exists and is a child of this shell (a pid that ended and was reused is not ours)
_bg_child(){ [[ "$(awk '{sub(/^.*\) /, ""); print $2}' "/proc/$1/stat" 2>/dev/null)" == "$BASHPID" ]]; }
bg_stop_all(){ local mode="$1" p live=() names="" end cmd
  for p in "${BG_PIDS[@]}"; do
    if [[ "$mode" == own ]]; then [[ -n "${BG_STOP[$p]:-}" ]] || continue
    else [[ -z "${BG_STOP[$p]:-}" ]] || continue; fi
    _bg_child "$p" && { live+=("$p"); names+="${BG_LABEL[$p]:-hook}($p) "; }
    [[ "$mode" == plain ]] || continue
    _bg_child "$p" && kill "$p" 2>/dev/null
  done
  if [[ "$mode" == own ]]; then
    for p in "${live[@]}"; do cmd="${BG_STOP[$p]:-}"; [[ -n "$cmd" ]] || continue   # an earlier command may have stopped it
      # shellcheck disable=SC2086  # the stop command is a word list
      $cmd; done
    for p in "${BG_PIDS[@]}"; do [[ -n "${BG_STOP[$p]:-}" ]] && bg_unregister "$p"; done
  else
    end=$((SECONDS + ${BG_STOP_GRACE_S:-5}))
    for p in "${live[@]}"; do while _bg_child "$p" && [[ $SECONDS -lt $end ]]; do sleep 0.1; done
      _bg_child "$p" && kill -9 "$p" 2>/dev/null; wait "$p" 2>/dev/null; done
    for p in "${BG_PIDS[@]}"; do [[ -z "${BG_STOP[$p]:-}" ]] && bg_unregister "$p"; done
  fi
  [[ -n "$names" ]] && echo "[rig] background helpers stopped ($mode): ${names% }"
  return 0; }
bg_sweep(){ local p x skip
  for p in $(jobs -rp); do skip=0; for x in "$@"; do [[ "$p" == "$x" ]] && skip=1; done; [[ $skip == 1 ]] && continue
    _bg_child "$p" || continue
    echo "[rig] WARN background job $p was not registered (bg_register): killed, so the final wait cannot hang on it"
    kill -9 "$p" 2>/dev/null; wait "$p" 2>/dev/null; BG_UNREGISTERED=$((BG_UNREGISTERED + 1)); done; return 0; }
