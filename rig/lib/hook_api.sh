# rig/lib/hook_api.sh: hook helper API functions for network manipulation and state comparison.
# Scenario hooks may rely on these functions.
rest()   { ip netns exec "${NS[$1]}" curl -s --max-time 4 "http://127.0.0.1:${REST[$1]}$2"; }

# same_chain compares header ids at the lower of the two full heights, not the live tips: a node that is still
# mining is always ahead, which is lag, not a fork.
same_chain(){
  local ha hb h ia ib; ha=$(full_height "$1"); hb=$(full_height "$2")
  h=$(( ha<hb ? ha : hb )); [[ "${h:-0}" -lt 1 ]] && { echo "NOHEIGHT"; return; }
  ia=$(header_at "$1" "$h"); ib=$(header_at "$2" "$h")
  if [[ -z "$ia" || -z "$ib" ]]; then echo "NOID@$h:$1=$ia:$2=$ib"   # unreadable: neither same nor different
  elif [[ "$ia" == "$ib" ]]; then echo "SAME@$h:$ia"; else echo "DIFF@$h:$1=$ia:$2=$ib"; fi
}

have_link(){ [[ -n "${LINK_OF["$1,$2"]:-}" ]]; }
link_netem(){ # $1=a $2=b $3=netem spec; replaces the a->b egress qdisc on a's veth
  _netem "$1" "$2" "$3" || return 1; rig_event link_netem "$1" "$2" "" "$3"; }
_netem(){ have_link "$1" "$2" || { echo "[rig] no link $1<->$2" >&2; return 1; }   # link_netem without the event
  local dev="${VETH["$1,$2"]}"
  # shellcheck disable=SC2086  # the spec is a word list
  ip netns exec "${NS[$1]}" tc qdisc replace dev "$dev" root netem $3 \
    || { harness_fail "netem '$3' on $1->$2 not applied"; return 1; }
}
# partition A B: drop 100% both directions (a soft cut that keeps the TCP sockets, unlike unplugging the link).
partition(){ have_link "$1" "$2" || { harness_fail "partition $1 $2: no such link"; return 1; }
  _netem "$1" "$2" "loss 100%" && _netem "$2" "$1" "loss 100%" || return 1; PARTITIONED["$1,$2"]=1; PARTITIONED["$2,$1"]=1
  rig_event partition "$1" "$2" "" "${EVENT_DETAIL:-}"; echo "[rig] partition $1<->$2 (100% loss)${EVENT_DETAIL:+ ($EVENT_DETAIL)}"; }
# heal A B: restore the link's configured shaping (delay/loss/jitter/rate), both directions; clean if it had none.
heal(){ have_link "$1" "$2" || { harness_fail "heal $1 $2: no such link"; return 1; }
  _netem "$1" "$2" "${CONFIGURED["$1,$2"]}" && _netem "$2" "$1" "${CONFIGURED["$2,$1"]}" || return 1; unset 'PARTITIONED[$1,$2]' 'PARTITIONED[$2,$1]'
  rig_event heal "$1" "$2" "" "${EVENT_DETAIL:-}"; echo "[rig] heal $1<->$2${EVENT_DETAIL:+ ($EVENT_DETAIL)}"; }

# same_state A B: the UTXO state root at the tip, compared only when both nodes are at the same full height
# (roots differ by height): SAME@h:root / DIFF@h:A=..:B=.. / NOHEIGHT, or, when the heights differ,
# LAG@ha,hb <label>: the lower node's best full-block header id against the higher node's header id at that
# height (/blocks/at/h, first entry, as same_chain reads it): "same-chain" (behind on the same chain), "fork"
# (different ids at the lower height), "unknown" (an id could not be read). The label follows a space, so callers
# that cut at ':' or match LAG@* are unaffected.
same_state(){
  local ia ib ha hb ra rb lo hi hl il ih; ia=$(rest "$1" /info); ib=$(rest "$2" /info)
  ha=$(jq -r '.fullHeight // 0' <<< "$ia"); hb=$(jq -r '.fullHeight // 0' <<< "$ib")
  [[ "${ha:-0}" -lt 1 || "${hb:-0}" -lt 1 ]] && { echo "NOHEIGHT"; return; }
  if [[ "$ha" != "$hb" ]]; then
    if [[ "$ha" -lt "$hb" ]]; then lo="$ia"; hi="$2"; hl="$ha"; else lo="$ib"; hi="$1"; hl="$hb"; fi
    il=$(jq -r '.bestFullHeaderId // empty' <<< "$lo"); ih=$(header_at "$hi" "$hl")
    if [[ -z "$il" || -z "$ih" ]]; then echo "LAG@$ha,$hb unknown"; elif [[ "$il" == "$ih" ]]; then echo "LAG@$ha,$hb same-chain"
    else echo "LAG@$ha,$hb fork"; fi; return
  fi
  ra=$(jq -r '.stateRoot // empty' <<< "$ia"); rb=$(jq -r '.stateRoot // empty' <<< "$ib")
  if [[ -z "$ra" || -z "$rb" ]]; then echo "NOROOT@$ha:$1=$ra:$2=$rb"   # unreadable: neither same nor different
  elif [[ "$ra" == "$rb" ]]; then echo "SAME@$ha:$ra"; else echo "DIFF@$ha:$1=$ra:$2=$rb"; fi; }

# settle_follow <leader> <follower> <min_h> [window_s=150]: bring a follower level with a mining leader, then pause
# the leader. Call it while the leader mines. It relaunches the leader with a slow poll (SETTLE_POLL, default 20s),
# waits up to window_s for same_state SAME@h with h >= min_h (or DIFF), then stops the leader's mining.
# Why a slow trickle instead of pausing first: pausing is a relaunch, and a 6.0.5 follower can hold the block
# sections it received before their header in its cache and not apply them once the header arrives, so it sits
# one or more blocks behind a paused leader indefinitely (addressed by ergoplatform/ergo#2549, in 6.0.6); any
# later block's sections drain that cache. A restarted follower does not recover either: it downloads no block
# sections until a new header arrives. With the leader still producing a block every poll, the follower gets that
# block and catches up; the check is taken at equal heights between blocks, then the leader pauses.
# In practice the relaunched leader mines one block within seconds of starting, then waits for the next poll.
# Sets SETTLE_STATE (the deciding same_state), SETTLE_TRICKLE (blocks the leader mined from the start of the settle,
# including any at its fast poll just before the relaunch),
# SETTLE_WAIT_S (seconds to decide) and SETTLE_AFTER (same_state right after the pause: a block mined in the last
# seconds may leave the follower one behind, reported rather than failed). Returns 0 on SAME@>=min_h, 1 otherwise.
# Call it directly, not in $(...), so the relaunch bookkeeping (PID, mining overrides) stays in the caller's shell.
settle_follow(){
  local m="$1" f="$2" t="$3" win="${4:-150}" end st h h0 rc=1 t0
  SETTLE_STATE=""; SETTLE_TRICKLE=0; SETTLE_AFTER=""
  # a relaunched node answers REST before its history is read (/info fullHeight 0 for a few seconds): wait for it
  h0=$(full_height "$m"); start_mining "$m" "${SETTLE_POLL:-20s}" >/dev/null; settle_height_back "$m"; t0=$SECONDS; end=$((SECONDS + win))
  while [[ $SECONDS -lt $end ]]; do
    st=$(same_state "$m" "$f"); SETTLE_STATE="$st"
    case "$st" in
      SAME@*) h=${st#SAME@}; h=${h%%:*}; [[ "${h:-0}" -ge "$t" ]] && { rc=0; break; } ;;
      DIFF@*) break ;;
    esac
    sleep 3
  done
  SETTLE_WAIT_S=$((SECONDS - t0)); SETTLE_TRICKLE=$(( $(full_height "$m") - h0 ))
  stop_mining "$m" >/dev/null; settle_height_back "$m"; SETTLE_AFTER=$(same_state "$m" "$f")
  return $rc; }
settle_height_back(){ local end=$((SECONDS + ${2:-60})); while [[ $SECONDS -lt $end && "$(full_height "$1")" -lt 1 ]]; do sleep 1; done; }
