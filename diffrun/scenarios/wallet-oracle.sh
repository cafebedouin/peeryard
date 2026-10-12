#!/usr/bin/env bash
# wallet-oracle: the wallet oracle (rig/WALLET-ORACLE.md) as a diffrun scenario. Every node of the network runs this
# role's jar (argv[1]); base against candidate is the comparison, and within each run the oracle compares a subject
# wallet put through a lifecycle event with a reference wallet (same keys, same jar, no event). One run = one rig
# network per event in WO_EVENTS, in order, each on a fresh scratch directory.
#   WO_EXAMPLE   restart (rig/examples/wallet-oracle-restart.{json,sh}) or fork (rig/examples/wallet-oracle-fork.*)
#   WO_EVENTS    space-separated events. restart example: restart, crash, rescan, none (A/A), rescan-from (positive
#                control); fork example: fork (the fork switch), none (no cut: A/A), rescan-from (fork + positive control)
#   WO_AT        restart example only: confirmed (default) or pending (compare before the pending payment confirms)
# Metrics: events, events_same, events_diff, and same (every event SAME). An event the oracle calls INCONCLUSIVE
# (not settled, a staging step that did not happen) makes the run INCONCLUSIVE (exit 3) and stops it there. Each
# event's verdict line and its per-field lines are printed ("[wallet-oracle-scenario] <event>: ..."), so a run's
# stdout.txt keeps the oracle's own SAME/DIFF per event.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
rig="$(realpath -e "$here/../../rig" 2>/dev/null)" || { echo "INCONCLUSIVE: rig/ not found beside diffrun/"; exit 3; }
jar="$(readlink -f "${1:-}")"; [[ -f "$jar" ]] || { echo "INCONCLUSIVE: no jar: ${1:-}"; exit 3; }
EX="${WO_EXAMPLE:-restart}"; EVENTS="${WO_EVENTS:-restart}"
case "$EX" in restart|fork) ;; *) echo "INCONCLUSIVE: WO_EXAMPLE must be restart or fork, not '$EX'"; exit 3 ;; esac
topo="$rig/examples/wallet-oracle-$EX.json"; hook="$rig/examples/wallet-oracle-$EX.sh"
WORKDIR="${WORKDIR:-$(mktemp -d)}"; mkdir -p "$WORKDIR"; WORKDIR="$(readlink -f "$WORKDIR")"
echo "[wallet-oracle-scenario] role=${DIFFRUN_ROLE:-none} jar=$(basename "$jar") ($(sha256sum "$jar" | cut -c1-16)) example=$EX events='$EVENTS' at=${WO_AT:-confirmed} java=$(${PEERYARD_JAVA:-java} -version 2>&1 | head -1)"
n=0; ns=0; nd=0; versions=""
for ev in $EVENTS; do
  n=$((n + 1))
  case "$EX:$ev" in
    restart:restart|restart:crash|restart:rescan|restart:none|restart:rescan-from) ev_env=("WO_EVENT=$ev") ;;
    fork:fork) ev_env=(WO_FORK=1) ;;
    fork:none) ev_env=(WO_FORK=0) ;;
    fork:rescan-from) ev_env=(WO_FORK=1 WO_CONTROL=rescan-from) ;;
    *) echo "INCONCLUSIVE: unknown event '$ev' for the $EX example"; exit 3 ;;
  esac
  out="$WORKDIR/rig-$n-$ev.txt"
  env "${ev_env[@]}" PEERYARD_JAR="$jar" SCRATCH="$WORKDIR/scratch-$n-$ev" bash "$rig/rig.sh" "$topo" "$hook" > "$out" 2>&1
  rc=$?
  grep -E '^\[(wo|wallet-oracle)\]|^\[rig\] (CAUSE|HARNESS-FAIL)' "$out" | sed "s/^/[$n:$ev] /" | tail -60
  line="$(grep -m1 -E '^\[wallet-oracle\] (SAME|DIFF|INCONCLUSIVE)' "$out")"
  v="$(grep -m1 '^\[wo\] versions ' "$out" | cut -d' ' -f3-)"
  echo "[wallet-oracle-scenario] $ev: ${line:-no verdict line} (rig exit $rc)"
  case "$line" in
    "[wallet-oracle] SAME@"*) ns=$((ns + 1)) ;;
    "[wallet-oracle] DIFF@"*) nd=$((nd + 1)) ;;
    *) c="$(grep -m1 -oE '^\[rig\] CAUSE.*' "$out")"; [[ -n "$c" ]] && echo "$c"
       echo "INCONCLUSIVE: event $ev: ${line:-rig exit $rc, no verdict line: $(tail -1 "$out")}"; exit 3 ;;
  esac
  jq -e 'type == "object" and length > 0' <<< "${v:-null}" >/dev/null 2>&1 || { echo "INCONCLUSIVE: event $ev: no versions line"; exit 3; }
  versions="$v"   # every node runs this role's jar; the last event's network reports them
done
echo "RESULT_JSON $(jq -cn --argjson v "$versions" --argjson n $n --argjson s $ns --argjson d $nd --arg ex "$EX" --arg jv "$(${PEERYARD_JAVA:-java} -version 2>&1 | head -1)" \
  '{schema_version: 1, scenario: ("wallet-oracle-" + $ex), runtime: {java: $jv}, versions: $v,
    metrics: {events: $n, events_same: $s, events_diff: $d, same: ($s == $n)}}')"
exit 0
