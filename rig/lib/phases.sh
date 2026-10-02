# shellcheck shell=bash
# phases.sh: a scenario as data. A hook sources this file and hands `phases` a heredoc, one phase per line; the
# grammar, the verbs and the verdict rules are in rig/PHASES.md. Every line is checked before any phase runs, so a
# typo costs one bring-up and runs nothing (INCONCLUSIVE, rig_cause BAD_SCENARIO:<line>:<text>). PHASES_CHECK=1:
# check only, print one line and return 0 (clean) or 1. Actions run in the hook's own shell, never in $(...).
_PH_ACT_ALL=" mine start_mining stop_mining partition heal link_netem flap crash revive launch wait_up set_cpus settle_follow pay wait_balance mark sleep "
_PH_ACT=" start_mining stop_mining partition heal link_netem flap crash revive settle_follow pay mark sleep "
_PH_CL_ALL=" same_chain same_state height synced balance peers topology settle fn value "
_PH_CL=" same_chain same_state height synced balance topology settle fn value "
_PH_RD_ALL=" height headers_height balance flap_last "
_PH_RD=" height balance flap_last "
_PH_OPS=" == != < <= > >= "
_PH_XRE='^[0-9+*/() -]+$'

# ---- checker ----
_ph_e(){ _PH_E=$1; return 1; }
_ph_node(){ local x; for x in "${NODES[@]}"; do [[ $x == "${1:-}" ]] && return 0; done; _ph_e "unknown node '${1:-}'"; }
_ph_int(){ [[ ${1:-} =~ ^[0-9]+$ ]] || _ph_e "not a whole number: '${1:-}'"; }
# an expression: @names recorded earlier (unconditionally), digits and + - * / ( ); it must evaluate with every @name = 1
_ph_xchk(){ local r=$1
  while [[ $r =~ @([a-z_][a-z0-9_]*) ]]; do
    [[ " $_PH_KNOWN " == *" ${BASH_REMATCH[1]} "* ]] || { _ph_e "@${BASH_REMATCH[1]} has no earlier unconditional record"; return; }
    r=${r/"@${BASH_REMATCH[1]}"/1}
  done
  [[ $r =~ $_PH_XRE ]] && ( : "$(( r ))" ) 2>/dev/null || _ph_e "bad expression '$1'"; }
_ph_cl_chk(){ local c=${1:-}; shift
  [[ $_PH_CL_ALL == *" $c "* ]] || { _ph_e "unknown clause '$c'"; return; }
  [[ $_PH_CL == *" $c "* ]] || { _ph_e "clause '$c' not implemented"; return; }
  case $c in
    same_chain|same_state) _ph_node "${1:-}" && _ph_node "${2:-}" || return
      case "$c ${3:-}" in
        "same_chain SAME"|"same_chain DIFF"|"same_state SAME") ;;
        "same_state SAME_OR_LAG") [[ $# == 3 ]] || { _ph_e "SAME_OR_LAG takes no height"; return; } ;;
        *) _ph_e "$c expects SAME$([[ $c == same_chain ]] && echo '|DIFF' || echo '|SAME_OR_LAG'), got '${3:-}'"; return ;;
      esac
      [[ $# == 3 ]] || { [[ $# == 5 && $4 == '>=' ]] || { _ph_e "expected [>= <expr>] after the token"; return; }; _ph_xchk "$5"; } ;;
    height|balance) [[ $# == 3 && $_PH_OPS == *" ${2:-} "* ]] || { _ph_e "expected $c <node> <op> <expr>"; return; }
      _ph_node "$1" && _ph_xchk "$3" ;;
    value) [[ $# == 3 && $_PH_OPS == *" ${2:-} "* ]] || { _ph_e "expected value <expr> <op> <expr>"; return; }
      [[ "$1$3" == *@* ]] || { _ph_e "value compares two constants (no @name on either side)"; return; }
      _ph_xchk "$1" && _ph_xchk "$3" ;;
    synced) [[ $# == 1 ]] || { _ph_e "expected synced <node>"; return; }; _ph_node "$1" ;;
    topology) [[ $# == 0 ]] || _ph_e "topology takes no argument" ;;
    settle) [[ $# == 0 ]] || { _ph_e "settle takes no argument"; return; }
      [[ $_PH_SEEN == *" settle_follow "* ]] || _ph_e "settle with no settle_follow line before it" ;;
    fn) [[ -n ${1:-} ]] && declare -F "$1" >/dev/null || _ph_e "fn: no function '${1:-}' defined" ;;
  esac; }
_ph_act_chk(){ local a=$1; shift
  [[ $_PH_ACT == *" $a "* ]] || { _ph_e "action '$a' not implemented"; return; }
  _PH_E=""
  case $a in
    start_mining) [[ $# == 1 || $# == 2 ]] && _ph_node "$1" ;;
    stop_mining|crash|revive) [[ $# == 1 ]] && _ph_node "$1" ;;
    partition|heal) [[ $# == 2 ]] && _ph_node "$1" && _ph_node "$2" ;;
    link_netem) [[ $# -ge 3 ]] && _ph_node "$1" && _ph_node "$2" ;;
    flap) [[ $# == 5 ]] && _ph_node "$1" && _ph_node "$2" && _ph_int "$3" && _ph_int "$4" && _ph_int "$5" ;;
    settle_follow) [[ $# == 3 || $# == 4 ]] && _ph_node "$1" && _ph_node "$2" && _ph_xchk "$3" && { [[ $# == 3 ]] || _ph_int "$4"; } ;;
    pay) [[ $# == 3 || $# == 4 ]] && _ph_node "$1" && _ph_node "$2" && _ph_int "$3" && { [[ $# == 3 ]] || _ph_int "$4"; } ;;
    mark) [[ $# == 1 ]] ;;
    sleep) [[ $# == 1 && $1 =~ ^[0-9]+(\.[0-9]+)?$ ]] ;;
  esac || _ph_e "${_PH_E:-wrong arguments to $a}"; }
_ph_chk(){ # <line n> <words...>: one line; sets _PH_E and returns 1 on the first problem
  local n=$1 cond=0; shift; _PH_E=""
  if [[ ${1:-} == when ]]; then
    [[ ${2:-} =~ ^[A-Z_][A-Z0-9_]*=.+$ ]] || { _ph_e "when needs VAR=value (VAR matching [A-Z_][A-Z0-9_]*, value not empty)"; return; }
    shift 2; cond=1; [[ ${1:-} != when ]] || { _ph_e "nested when"; return; }
  fi
  local v=${1:-}; shift
  case $v in
    floor|wait) local -a w=("$@"); local t=0 i
      for i in "${!w[@]}"; do [[ ${w[i]} == timeout ]] && t=$i; done
      (( t >= 1 )) && [[ ${w[t+1]:-} =~ ^[0-9]+$ ]] || { _ph_e "$v needs <clause> timeout <seconds>"; return; }
      case "$v:$(( ${#w[@]} - t ))" in
        floor:2|wait:2) ;;
        floor:4) [[ ${w[t+2]} == cause && ${w[t+3]} =~ ^[A-Z_][A-Z0-9_]*$ ]] || { _ph_e "expected cause NAME"; return; } ;;
        *) _ph_e "unexpected words after timeout"; return ;;
      esac
      _ph_cl_chk "${w[@]:0:t}" || return ;;
    pass) local lb="L$n"
      if [[ ${1:-} == *: ]]; then lb=${1%:}; shift
        [[ $lb =~ ^[a-z_][a-z0-9_]*$ ]] || { _ph_e "bad label '$lb'"; return; }
        [[ " $_PH_LABELS " != *" $lb "* ]] || { _ph_e "duplicate label '$lb'"; return; }
        [[ " $_PH_RECS " != *" $lb "* ]] || { _ph_e "label '$lb' collides with a record"; return; }
      fi
      _PH_LABELS+=" $lb"; _ph_cl_chk "$@" || return ;;
    record) [[ $# -ge 2 && ${1:-} =~ ^[a-z_][a-z0-9_]*$ ]] || { _ph_e "expected record NAME <reader> [node]"; return; }
      [[ $_PH_RD_ALL == *" $2 "* ]] || { _ph_e "unknown reader '$2'"; return; }
      [[ $_PH_RD == *" $2 "* ]] || { _ph_e "reader '$2' not implemented"; return; }
      if [[ $2 == flap_last ]]; then [[ $# == 2 ]] || { _ph_e "flap_last takes no node"; return; }
      else [[ $# == 3 ]] || { _ph_e "expected record NAME $2 <node>"; return; }; _ph_node "$3" || return; fi
      [[ " $_PH_LABELS " != *" $1 "* ]] || { _ph_e "record '$1' collides with a label"; return; }
      _PH_RECS+=" $1"; (( cond )) || _PH_KNOWN+=" $1" ;;
    *) [[ $_PH_ACT_ALL == *" $v "* ]] || { _ph_e "unknown verb '$v'"; return; }
      _ph_act_chk "$v" "$@" || return
      if [[ $v == pay ]]; then [[ " $_PH_LABELS " != *" pay_sent "* ]] || { _ph_e "pay_sent collides with a label"; return; }
        _PH_RECS+=" pay_sent"; (( cond )) || _PH_KNOWN+=" pay_sent"; fi
      [[ $v != settle_follow ]] || _PH_SEEN+=" settle_follow " ;;
  esac
  [[ $v != pass && $v != wait ]] || _PH_CLAIMS=$((_PH_CLAIMS + 1))
  (( cond )) && return 0   # _PH_TAIL: the first unconditional action after the last unconditional pass or wait
  case $v in pass|wait) _PH_TAIL="" ;; floor|record) ;; *) [[ -n $_PH_TAIL ]] || _PH_TAIL="$n:$v" ;; esac; }

# ---- runner ----
_ph_fix(){ [[ -n $_PH_V ]] || { _PH_V=$1; _PH_C=$2; }; }   # the first verdict-bearing event fixes verdict and cause
_ph_x(){ local r=$1   # evaluate an expression with the recorded values; the caller runs it in $(...)
  while [[ $r =~ @([a-z_][a-z0-9_]*) ]]; do r=${r/"@${BASH_REMATCH[1]}"/${_PH_REC[${BASH_REMATCH[1]}]:-x}}; done
  [[ $r =~ $_PH_XRE ]] || return 1; echo "$(( r ))"; }
_ph_xv(){ _PH_T=$(_ph_x "$1" 2>/dev/null) && return 0
  echo "[phases]   expression error: $1"; _ph_fix INCONCLUSIVE "EXPR_ERROR:$_PH_LN"; return 2; }
_ph_cmp(){ [[ $1 =~ ^-?[0-9]+$ && $3 =~ ^-?[0-9]+$ ]] || return 1
  case $2 in '==') (( $1 == $3 )) ;; '!=') (( $1 != $3 )) ;; '<') (( $1 < $3 )) ;; '<=') (( $1 <= $3 )) ;; '>') (( $1 > $3 )) ;; '>=') (( $1 >= $3 )) ;; esac; }
_ph_cl(){ local c=$1 s h; shift; _PH_VAL=""
  case $c in
    same_chain|same_state) s=$("$c" "$1" "$2"); _PH_VAL=$s
      case $3 in SAME) [[ $s == SAME@* ]] ;; DIFF) [[ $s == DIFF@* ]] ;;
        SAME_OR_LAG) [[ $s == SAME@* || ( $s == LAG@* && $s == *" same-chain" ) ]] ;; esac || return 1
      [[ ${4:-} == '>=' ]] || return 0
      _ph_xv "$5" || return 2; h=${s#*@}; h=${h%%:*}; _PH_VAL+=" (need >= $_PH_T)"; _ph_cmp "$h" '>=' "$_PH_T" ;;
    height|balance) if [[ $c == height ]]; then s=$(full_height "$1"); else s=$(balance "$1"); fi
      _ph_xv "$3" || return 2; _PH_VAL="$c $1 = $s (need $2 $_PH_T)"; _ph_cmp "$s" "$2" "$_PH_T" ;;
    value) _ph_xv "$1" || return 2; s=$_PH_T; _ph_xv "$3" || return 2; _PH_VAL="$s $2 $_PH_T"; _ph_cmp "$s" "$2" "$_PH_T" ;;
    synced) s=$(full_height "$1"); h=$(rest "$1" /info | jq -r '.headersHeight // 0' 2>/dev/null)
      _PH_VAL="$1 full=$s headers=$h"; [[ $s =~ ^[0-9]+$ && $s -ge 1 && $s == "$h" ]] ;;
    topology) s=$(check_topology); h=$?; printf '%s\n' "$s"; _PH_VAL="check_topology rc=$h"; return $(( h != 0 )) ;;
    settle) _PH_VAL="settle_follow rc=${_PH_SRC:-none} ${SETTLE_STATE:-}"; [[ ${_PH_SRC:-1} == 0 ]] ;;
    fn) "$@"; h=$?; _PH_VAL="fn $1 rc=$h"; return $(( h != 0 )) ;;
  esac; }
_ph_clause(){ _ph_cl "$@"; local rc=$?
  (( rc == 2 )) || echo "[phases]   $_PH_VAL -> $( (( rc == 0 )) && echo true || echo false)"; return $rc; }
_ph_run(){ local v=$1; shift
  case $v in
    floor|wait) local -a w=("$@"); local t=0 i end cause=NO_FLOOR rc
      for i in "${!w[@]}"; do [[ ${w[i]} == timeout ]] && t=$i; done
      end=$((SECONDS + w[t+1])); [[ -z ${w[t+3]:-} ]] || cause=${w[t+3]}
      while :; do
        _ph_clause "${w[@]:0:t}"; rc=$?
        (( rc == 0 )) && { [[ $v == floor ]] || _PH_NW=$((_PH_NW + 1)); return 0; }
        (( rc == 2 || SECONDS >= end )) && break; sleep 3
      done
      (( rc == 2 )) && return 1
      if [[ $v == floor ]]; then echo "[phases]   floor timed out: $cause"; _ph_fix INCONCLUSIVE "$cause"
      else echo "[phases]   wait timed out"; _ph_fix FAIL "WAIT_TIMEOUT:$_PH_LN"; fi
      return 1 ;;
    pass) local lb="L$_PH_LN" rc; [[ $1 != *: ]] || { lb=${1%:}; shift; }
      _ph_clause "$@"; rc=$?; (( rc == 2 )) && return 1
      _PH_NP=$((_PH_NP + 1)); _PH_PORD+=" $lb"
      if (( rc == 0 )); then _PH_PASS[$lb]=true
      else _PH_PASS[$lb]=false; echo "[phases]   pass $lb does not hold"; _ph_fix FAIL "CLAUSE:$lb $_PH_VAL"; fi ;;
    record) local val
      case $2 in height) val=$(full_height "$3") ;; balance) val=$(balance "$3") ;; flap_last) val=${FLAP_LAST_HEIGHT:-} ;; esac
      echo "[phases]   $1 = ${val:-(empty)}"
      if ! [[ $val =~ ^[0-9]+$ ]] || [[ $2 == height && $val == 0 ]]; then _ph_fix INCONCLUSIVE "RECORD_EMPTY:$1"; return 1; fi
      [[ -v "_PH_REC[$1]" ]] || _PH_RORD+=" $1"; _PH_REC[$1]=$val ;;
    settle_follow) _ph_xv "$3" || return 1
      echo "[phases]   settle_follow $1 $2 min_h=$_PH_T window=${4:-150}"
      settle_follow "$1" "$2" "$_PH_T" "${4:-150}"; _PH_SRC=$?
      echo "[phases]   settle rc=$_PH_SRC: ${SETTLE_STATE:-} (after pause: ${SETTLE_AFTER:-}; ${SETTLE_WAIT_S:-?}s; leader mined ${SETTLE_TRICKLE:-?})" ;;
    pay) local i id c=${4:-1} ok=0 tmp; tmp=$(mktemp)
      for ((i = 1; i <= c; i++)); do
        pay "$1" "$2" "$3" >"$tmp"; id=$(<"$tmp")
        if [[ $id =~ ^[0-9a-f]{64}$ ]]; then ok=$((ok + 1)); else echo "[phases]   pay $i rejected: $id"; fi
        (( i < c )) && sleep 0.15
      done; rm -f "$tmp"
      [[ -v "_PH_REC[pay_sent]" ]] || _PH_RORD+=" pay_sent"; _PH_REC[pay_sent]=$(( ${_PH_REC[pay_sent]:-0} + ok ))
      echo "[phases]   pay: $ok/$c accepted (pay_sent ${_PH_REC[pay_sent]})" ;;
    link_netem) link_netem "$1" "$2" "${*:3}"; echo "[phases]   rc=$?" ;;
    sleep) sleep "$1" ;;
    *) "$v" "$@"; echo "[phases]   rc=$?" ;;
  esac; }
_ph_end(){ local name=$1 m='{}' vs='{}' k
  if [[ -z $_PH_V ]]; then
    if (( _PH_NP + _PH_NW == 0 )); then _PH_V=INCONCLUSIVE; _PH_C=NO_CLAIM_EVALUATED; else _PH_V=PASS; fi
  fi
  rig_verdict=$_PH_V; rig_cause=$_PH_C
  for k in $_PH_PORD; do m=$(jq -c --arg k "$k" --argjson v "${_PH_PASS[$k]}" '. + {($k): $v}' <<<"$m"); done
  for k in $_PH_RORD; do m=$(jq -c --arg k "$k" --argjson v "${_PH_REC[$k]}" '. + {($k): $v}' <<<"$m"); done
  for k in "${NODES[@]}"; do
    vs=$(jq -c --arg k "$k" --arg v "$(rest "$k" /info | jq -r '.appVersion // "null"' 2>/dev/null)" '. + {($k): $v}' <<<"$vs"); done
  echo "[phases] === $name: $rig_verdict ===${rig_cause:+ ($rig_cause)}"
  echo "RESULT_JSON $(jq -cn --arg s "${name,,}" --argjson v "$vs" --argjson m "$m" '{schema_version: 1, scenario: $s, versions: $v, metrics: $m}')"; }

phases(){
  rig_verdict=INCONCLUSIVE; rig_cause=PHASES_ABORTED   # anything not caught below still ends as a named INCONCLUSIVE
  local base=${BASH_LINENO[0]} name i ln N
  name=$(basename "${HOOK:-phases}" .sh); name=${name^^}
  local -a raw=() ph=() pn=() w=()
  mapfile -t raw
  _PH_KNOWN="" _PH_RECS="" _PH_LABELS="" _PH_SEEN="" _PH_CLAIMS=0 _PH_TAIL="" _PH_E="" _PH_V="" _PH_C="" _PH_NP=0 _PH_NW=0
  _PH_PORD="" _PH_RORD="" _PH_SRC="" _PH_LN=0; declare -gA _PH_REC=() _PH_PASS=()
  local bad=""
  for i in "${!raw[@]}"; do
    ln=$((i + 1)); read -ra w <<<"${raw[i]}"
    [[ ${#w[@]} == 0 || ${w[0]} == \#* ]] && continue
    _ph_chk "$ln" "${w[@]}" || { bad="$ln:${raw[i]}"; break; }
    ph+=("${raw[i]}"); pn+=("$ln")
  done
  [[ -n $bad || $_PH_CLAIMS -gt 0 ]] || { bad="0:"; _PH_E="no pass and no wait"; }
  if [[ -n $bad ]]; then
    echo "[phases] BAD_SCENARIO line ${bad%%:*} (file line $((base + ${bad%%:*}))): $_PH_E: ${bad#*:}"
    [[ ${PHASES_CHECK:-0} == 1 ]] && return 1
    _PH_V=INCONCLUSIVE; _PH_C="BAD_SCENARIO:$bad"; _ph_end "$name"; return 0
  fi
  N=${#ph[@]}
  if [[ ${PHASES_CHECK:-0} == 1 ]]; then
    [[ -z $_PH_TAIL ]] || echo "[phases] WARN line ${_PH_TAIL%%:*}: action '${_PH_TAIL#*:}' after the last pass or wait is not observed"
    echo "[phases] check $name: ok ($N phases)"; return 0; fi
  for i in "${!ph[@]}"; do
    _PH_LN=${pn[i]}; read -ra w <<<"${ph[i]}"
    if [[ ${w[0]} == when ]]; then
      local var=${w[1]%%=*} val=${w[1]#*=}
      if [[ ${!var:-} != "$val" ]]; then echo "[phases] $((i + 1))/$N skipped ($var is not '$val'): ${ph[i]}"; continue; fi
      w=("${w[@]:2}")
    fi
    echo "[phases] $((i + 1))/$N ${ph[i]}"
    _ph_run "${w[@]}" || break
  done
  _ph_end "$name"; }
