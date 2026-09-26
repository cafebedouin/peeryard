#!/usr/bin/env bash
# devnet.sh: a devnet that stays up. Starts a topology with the rig and leaves it running until `down`; the
# nodes' data directories persist across down/up, so the chain continues where it stopped.
#
#   rig/devnet.sh up <topology.json> [name]     start (name defaults to "default"); PEERYARD_* env applies
#   rig/devnet.sh status [name]                 rig alive? node heights and versions
#   rig/devnet.sh curl <node> <path> [name]     query a node's REST API from your shell, e.g. curl A /info
#   rig/devnet.sh logs <node> [name]            tail the node's log
#   rig/devnet.sh down [name]                   stop the nodes; data kept
#   rig/devnet.sh wipe [name]                   remove the devnet's directory (chain and logs) after down
#   rig/devnet.sh expose <node> <hostport> [name]   forward 127.0.0.1:<hostport> on the host to the node's REST
#                                               API (python3; a panel, explorer or wallet can then be pointed at it)
#   rig/devnet.sh unexpose <node> <hostport> [name]
#
# The nodes live inside the rig's unprivileged user and network namespaces, so `curl` enters those namespaces
# with nsenter (allowed for the user who created them; no root). State: $PEERYARD_DEVNET_DIR (default
# ~/.peeryard/devnet)/<name>: topology.json, rig.pid (inner rig), launcher.pid, out/ (logs, effective.json), data_*.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${PEERYARD_DEVNET_DIR:-$HOME/.peeryard/devnet}"
cmd="${1:-}"; shift || true
die(){ echo "devnet: $*" >&2; exit 2; }
# setdir <name>: validate the devnet name (it becomes a path under $ROOT that `wipe` removes) and set d.
setdir(){ local nm="${1:-default}"
  [[ "$nm" =~ ^[A-Za-z0-9_-]+$ ]] || die "bad devnet name '$nm' (letters, digits, _ and - only)"; d="$ROOT/$nm"; }
# alive <dir>: the pid in rig.pid is running AND is this devnet's rig. A stale rig.pid whose pid was reused by
# another process must not be trusted or signalled: the inner rig runs `bash .../rig.sh` with SCRATCH=<dir> in
# its environment (devnet.sh up sets it), so both are checked in /proc.
alive(){ local d="$1" pid
  [[ -f "$d/rig.pid" ]] || return 1; pid="$(cat "$d/rig.pid" 2>/dev/null)"; [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  tr '\0' '\n' < "/proc/$pid/cmdline" 2>/dev/null | grep -q 'rig\.sh$' || return 1
  tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null | grep -qxF "SCRATCH=$d"; }
enter(){ # enter <dir> <node> <cmd...>: run inside the rig's user+mount+net namespaces, then the node's netns
  local d="$1" n="$2"; shift 2; local pid; pid="$(cat "$d/rig.pid")"
  nsenter --preserve-credentials -U -m -n -t "$pid" -- ip netns exec "ns_$n" "$@"; }
nodes_of(){ jq -r '.nodes[].name' "$1/topology.json"; }
rest_of(){ jq -r --arg n "$2" 'first(.nodes[]|select(.name==$n).rest) // 9052' "$1/topology.json"; }

case "$cmd" in
  up)
    cfg="${1:?usage: devnet.sh up <topology.json> [name]}"; setdir "${2:-}"
    [[ -f "$cfg" ]] || die "no topology: $cfg"
    alive "$d" && die "already up: $d (rig pid $(cat "$d/rig.pid")); use status/down"
    mkdir -p "$d/out"; cp "$cfg" "$d/topology.json"; rm -f "$d/stop" "$d/rig.pid"
    # SCRATCH is the persistent dir; KEEP_DATA keeps the chain; log_dir inside it
    jq '.log_dir = $l' --arg l "$d/out" "$d/topology.json" > "$d/topology.effective.json"
    ( SCRATCH="$d" PEERYARD_KEEP_DATA=1 nohup bash "$HERE/rig.sh" "$d/topology.effective.json" "$HERE/examples/hold.sh" > "$d/rig.log" 2>&1 & echo $! > "$d/launcher.pid" )
    for _ in $(seq 1 "${PEERYARD_UP_TIMEOUT:-60}"); do [[ -f "$d/rig.pid" ]] && grep -q 'devnet up' "$d/rig.log" && break; sleep 1; done
    if grep -q 'devnet up' "$d/rig.log"; then echo "devnet '${2:-default}' up ($d)"; grep -A20 'devnet up' "$d/rig.log" | sed -n '2,20p' | grep -E '^\s+[A-Za-z0-9]+ ip=' ; echo "effective: $d/out/effective.json"
    elif alive "$d" || kill -0 "$(cat "$d/launcher.pid" 2>/dev/null)" 2>/dev/null; then echo "devnet '${2:-default}' still starting after ${PEERYARD_UP_TIMEOUT:-60} s (rig alive); \`devnet.sh status ${2:-default}\` will tell; rig.log: $d/rig.log"
    else echo "devnet did not come up; rig.log:"; tail -20 "$d/rig.log"; exit 1; fi ;;
  status)
    setdir "${1:-}"; [[ -d "$d" ]] || die "no devnet '${1:-default}' under $ROOT"
    if alive "$d"; then echo "up (rig pid $(cat "$d/rig.pid"), since $(stat -c %y "$d/rig.pid" | cut -d. -f1))"; else echo "down (data kept in $d)"; exit 1; fi
    for n in $(nodes_of "$d"); do i="$(enter "$d" "$n" curl -s --max-time 4 "http://127.0.0.1:$(rest_of "$d" "$n")/info" 2>/dev/null)"
      printf '  %-4s height=%s headers=%s peers=%s version=%s\n' "$n" "$(jq -r '.fullHeight // "?"' <<< "$i")" "$(jq -r '.headersHeight // "?"' <<< "$i")" "$(jq -r '.peersCount // "?"' <<< "$i")" "$(jq -r '.appVersion // "?"' <<< "$i")"; done ;;
  curl)
    n="${1:?usage: devnet.sh curl <node> <path> [name]}"; p="${2:?path}"; setdir "${3:-}"; alive "$d" || die "devnet is down"
    enter "$d" "$n" curl -s --max-time 10 "http://127.0.0.1:$(rest_of "$d" "$n")$p"; echo ;;
  logs)
    n="${1:?usage: devnet.sh logs <node> [name]}"; setdir "${2:-}"; tail -n "${LINES_TO_SHOW:-40}" "$d/out/node_$n.log" ;;
  down)
    setdir "${1:-}"; alive "$d" || { echo "already down"; exit 0; }
    for pf in "$d"/expose_*.pid; do [[ -f "$pf" ]] && { kill "$(cat "$pf")" 2>/dev/null; rm -f "$pf"; }; done
    touch "$d/stop"; for _ in $(seq 1 60); do alive "$d" || break; sleep 1; done
    alive "$d" && { echo "rig did not stop on request; sending TERM"; kill "$(cat "$d/rig.pid")" 2>/dev/null; sleep 3; }
    alive "$d" && die "still up (pid $(cat "$d/rig.pid"))"; echo "down; chain kept in $d (up again with the same name to continue)" ;;
  wipe)
    setdir "${1:-}"; alive "$d" && die "still up; run down first"; rm -rf "$d"; echo "removed $d" ;;
  expose)
    # A host-side forwarder: python3 listens on 127.0.0.1:<hostport>; each connection is handed (as stdin and
    # stdout) to a bash inside the rig's namespaces that opens the node's REST port with /dev/tcp and pumps
    # bytes both ways. No root, no socat; the forwarder dies with `unexpose` or `down`.
    n="${1:?usage: devnet.sh expose <node> <hostport> [name]}"; hp="${2:?hostport}"; setdir "${3:-}"; alive "$d" || die "devnet is down"
    command -v python3 >/dev/null || die "expose needs python3"
    pf="$d/expose_${n}_${hp}.pid"; [[ -f "$pf" ]] && kill -0 "$(cat "$pf")" 2>/dev/null && die "already exposed (pid $(cat "$pf"))"
    nohup python3 - "$hp" "$(cat "$d/rig.pid")" "$n" "$(rest_of "$d" "$n")" > "$d/expose_${n}_${hp}.log" 2>&1 <<'PY' &
import socket, subprocess, sys, threading
hostport, rigpid, node, rest = int(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4]
cmd = ["nsenter", "--preserve-credentials", "-U", "-m", "-n", "-t", rigpid, "--", "ip", "netns", "exec", "ns_" + node,
       "bash", "-c", "exec 3<>/dev/tcp/127.0.0.1/%s; cat <&3 & cat >&3; wait" % rest]
def serve(c):
    with c:
        subprocess.run(cmd, stdin=c.fileno(), stdout=c.fileno(), stderr=subprocess.DEVNULL)
srv = socket.socket(); srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); srv.bind(("127.0.0.1", hostport)); srv.listen(16)
print("exposing node %s REST %s on 127.0.0.1:%d" % (node, rest, hostport), flush=True)
while True:
    conn, _ = srv.accept(); threading.Thread(target=serve, args=(conn,), daemon=True).start()
PY
    echo $! > "$pf"; sleep 1; kill -0 "$(cat "$pf")" 2>/dev/null || { cat "$d/expose_${n}_${hp}.log"; die "forwarder exited"; }
    echo "node $n REST on http://127.0.0.1:$hp (pid $(cat "$pf")); unexpose with: devnet.sh unexpose $n $hp ${3:-}" ;;
  unexpose)
    n="${1:?usage: devnet.sh unexpose <node> <hostport> [name]}"; hp="${2:?hostport}"; setdir "${3:-}"; pf="$d/expose_${n}_${hp}.pid"
    [[ -f "$pf" ]] || die "not exposed"; kill "$(cat "$pf")" 2>/dev/null; rm -f "$pf"; echo "unexposed $n:$hp" ;;
  *) sed -n '2,17p' "$0"; exit 2 ;;
esac
