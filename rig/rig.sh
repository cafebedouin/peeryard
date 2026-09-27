#!/usr/bin/env bash
# rig.sh: run N real Ergo nodes on one Linux host, each in its own network namespace, with per-link and
# per-direction netem (delay, loss, jitter), then hand control to a hook script that drives the experiment.
#
#   rig.sh <topology.json> <hook.sh>
#
# No root and no Docker: the script re-executes itself under `unshare -Urmn` (user, mount and net namespaces),
# which gives it CAP_NET_ADMIN inside the namespace, and mounts a tmpfs over /run so `ip netns` works.
# Each node runs `java -jar <jar> --devnet` with a private network magic, so it cannot talk to any other network.
#
# topology.json (see rig/README.md for the full schema):
#   { "jar": "/path/ergo-6.0.6.jar",
#     "nodes": [ {"name": "A", "mining": true, "knownPeers": []},
#                {"name": "B", "mining": false, "knownPeers": ["A"], "jar": "${PEERYARD_JAR_B}"} ],
#     "links": [ {"a": "A", "b": "B", "delay_ms": 0, "loss_pct": 0, "jitter_ms": 0, "rate_kbit": 0} ] }
# A node's own "jar" overrides the top-level one (mixed versions on one network); "${VAR}" in a jar path is
# expanded from the environment. A node may be another implementation: "kind": "arkadianet" | "ergo-node-rust"
# (default "jvm") with "bin": the node binary (or PEERYARD_ARKADIANET_BIN / PEERYARD_ERGO_NODE_RUST_BIN); such a
# topology must use the chain preset "rust-devnet" (see below), the private devnet those binaries ship with.
# Bring-up gate: before the hook runs, every link between launched nodes must be connected both ways within
# PEERYARD_BRINGUP_S (default 90) s. A node that dials a peer before the peer listens drops it and does not retry, so
# a link still missing after PEERYARD_BRINGUP_GRACE_S (default 30) s of the nodes' own dialling is re-dialled once from
# a JVM end (POST /peers/connect). A link still missing is a bring-up failure
# (exit 2), not a verdict. "bringup_links": false at the top level skips the gate (a topology whose links are meant
# not to connect, e.g. examples/magic).
#
# hook.sh is sourced inside the namespace once every node is up. It can use:
#   rest <node> <path>              curl that node's REST API (inside its namespace)
#   node_ip <node>                  the node's primary IP
#   applied_header <node>           best full-block header id (falls back to best header)
#   header_at <node> <height>       header id at a height
#   full_height <node>              /info fullHeight
#   same_chain <a> <b>              compares header ids at the lower of the two heights: SAME@h / DIFF@h / NOHEIGHT
#   same_state <a> <b>              compares UTXO state roots at equal full heights: SAME@h / DIFF@h /
#                                   LAG@ha,hb same-chain|fork|unknown (header ids at the lower height)
#   settle_follow <leader> <follower> <min_h> [window_s]   with the leader mining slowly, wait for same_state
#                                   SAME@h>=min_h (or DIFF), then pause the leader (sets SETTLE_STATE, SETTLE_TRICKLE, ...)
#   peers_of <node>; check_topology  connected peer names; every unpartitioned link connected both ways, no extra peer
#   orphans_between <node> <h0> <h1>  header ids beyond the first per height (siblings later abandoned)
#   rss_mb <node> / data_mb <node>   resident memory and data-directory size in MB
#   link_netem <a> <b> <spec>       replace netem on the a->b direction, e.g. link_netem A B "delay 40ms loss 5%"
#   partition <a> <b> / heal <a> <b>  cut a link (100% loss both ways) / restore its configured shaping
#   launch <node>; wait_up <node>   first launch of a node declared with "defer": true
#   relaunch <node>                 stop and restart a node (its chain is kept)
#   crash <node> / revive <node>    SIGKILL a node and leave it down / bring it back (chain restored from disk)
#   stop_mining / start_mining <node> [poll]   restart the node with mining off / on
#   mine <node> <n> [poll]          mine about n blocks, then stop mining
#   address <node> / balance <node> / pay <from> <to> <nanoerg> / wait_balance <node> <min> [s] / block_txs <node> <h>
#                                   wallet helpers: real transactions from a miner's rewards (see rig/README.md)
#   txchain <from> <n> [nanoerg]    n self-payments in a burst -> a dependency chain in the mempool
#   send_fee <from> <to> <nanoerg> <fee>   a payment with an explicit fee (wallet/transaction/send with "fee")
#   corrupt <node> <injury>         injure a stopped node's data directory (truncate-state | drop-undo |
#                                   drop-history-objects | zero-state-log), for restart-recovery tests
#   solve_start <node> / solve_stop <node>   external solver loop for a node that serves /mining/candidate but has
#                                   no internal miner (an arkadianet node with "mining": true): at difficulty 1
#                                   every nonce solves, so the loop submits a fixed solution per candidate
#   mempool_ids <node> / mempool_size <node>   the unconfirmed pool's tx ids (in listed order) / its count
#   and the variables NODES, RIG_LOG_DIR, SCRATCH, CONF_OVR (per-node extra HOCON for a deferred launch).
#   A hook sets rig_verdict=PASS|FAIL|INCONCLUSIVE; rig.sh exits 1 on FAIL, 3 on INCONCLUSIVE.
# Env overrides: PEERYARD_CHAIN (preset), PEERYARD_MINE_POLL, PEERYARD_DURATION (hooks read it), PEERYARD_KEEP_DATA=1.
# The run's effective configuration (jars, chain, links, polls, duration) is written to $RIG_LOG_DIR/effective.json.
# Topology "chain": "current" (default) | "matrix" | "devnet" | "rust-devnet", or an object with blockInterval /
# minerRewardDelay / genesisStateDigestHex, sets the chain parameters all nodes share (see rig/README.md).
#
# Env: PEERYARD_JAR (used when the topology has no "jar"), SCRATCH (default: a fresh mktemp -d),
# PEERYARD_JAVA (the java binary for JVM nodes, default `java` on PATH), PEERYARD_JAVA_OPTS (default -Xmx512m),
# PEERYARD_UP_TIMEOUT (seconds a node may take to answer on REST at bring-up, default 60; a node that never
# answers aborts the run with a named error).
# Nodes are stopped on exit.
set -uo pipefail

MNEMONIC="ozone drill grab fiber curtain grace pudding thank cruise elder eight picnic"  # the node's public test mnemonic
JAVA_BIN="${PEERYARD_JAVA:-java}"; JAVA_OPTS="${PEERYARD_JAVA_OPTS:--Xmx512m}"
API_KEY_HASH="324dcf027dd4a30a932c441f365a25e86b173defa4b8e58948253471b81b72cf"          # Blake2b256("hello")

# ---------------------------------------------------------------------------
if [[ "${RIG_INNER:-0}" != "1" ]]; then
  # ---- outer: validate the arguments, then re-exec inside the user + mount + net namespace ----
  CFG="${1:?usage: rig.sh <topology.json> <hook.sh>}"
  HOOK="${2:?usage: rig.sh <topology.json> <hook.sh>}"
  [[ -f "$CFG" ]]  || { echo "no topology: $CFG" >&2; exit 2; }
  [[ -f "$HOOK" ]] || { echo "no hook: $HOOK" >&2; exit 2; }
  for c in jq curl unzip ip tc unshare; do command -v "$c" >/dev/null || { echo "missing: $c" >&2; exit 2; }; done
  command -v "$JAVA_BIN" >/dev/null || { echo "missing: $JAVA_BIN (PEERYARD_JAVA)" >&2; exit 2; }
  # Every node needs a jar: nodes[].jar, else the top-level "jar", else PEERYARD_JAR. Checked here, resolved again inside.
  # shellcheck disable=SC2016  # a jq program: $ENV is jq's, not the shell's
  JAR_XP='def xp: if type == "string" then gsub("\\$\\{(?<v>[A-Za-z_][A-Za-z0-9_]*)\\}"; ($ENV[.v] // "")) else . end;'
  # A "${VAR}" that expands to nothing is an error, never a silent fall-back to the default jar.
  raw_top="$(jq -r '.jar // ""' "$CFG")"
  DEF_JAR="$(jq -r --arg d "${PEERYARD_JAR:-}" "$JAR_XP"' (.jar // $d) | xp' "$CFG")"
  [[ -n "$raw_top" && -z "$DEF_JAR" ]] && { echo "topology \"jar\" is '$raw_top' but expands to nothing (unset variable?)" >&2; exit 2; }
  while IFS=$'\t' read -r n kind raw j rawb b; do
    case "$kind" in
      jvm)
        [[ -n "$raw" && -z "$j" ]] && { echo "node $n: jar is '$raw' but expands to nothing (unset variable?)" >&2; exit 2; }
        j="${j:-$DEF_JAR}"
        [[ -f "$j" ]] || { echo "no node jar for $n: set nodes[].jar, \"jar\" in the topology, or PEERYARD_JAR (got '$j')" >&2; exit 2; } ;;
      arkadianet|ergo-node-rust)
        # another implementation: its binary comes from nodes[].bin or the kind's environment variable
        [[ -n "$rawb" && -z "$b" ]] && { echo "node $n: bin is '$rawb' but expands to nothing (unset variable?)" >&2; exit 2; }
        if [[ -z "$b" ]]; then case "$kind" in arkadianet) b="${PEERYARD_ARKADIANET_BIN:-}" ;; ergo-node-rust) b="${PEERYARD_ERGO_NODE_RUST_BIN:-}" ;; esac; fi
        [[ -x "$b" ]] || { echo "no node binary for $n (kind $kind): set nodes[].bin or PEERYARD_$(echo "$kind" | tr 'a-z-' 'A-Z_')_BIN (got '$b')" >&2; exit 2; } ;;
      *) echo "node $n: unknown kind '$kind' (jvm | arkadianet | ergo-node-rust)" >&2; exit 2 ;;
    esac
  done < <(jq -r "$JAR_XP"' .nodes[] | [.name, (.kind // "jvm"), (.jar // ""), ((.jar // "") | xp), (.bin // ""), ((.bin // "") | xp)] | @tsv' "$CFG")
  RIG_CFG="$(readlink -f "$CFG")"; RIG_HOOK="$(readlink -f "$HOOK")"
  export RIG_INNER=1 RIG_CFG RIG_HOOK RIG_JAR="$DEF_JAR"
  unshare -Urmn true 2>/dev/null || { echo "unprivileged user namespaces are unavailable here (Ubuntu 23.10+: sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0; or use a VM)" >&2; exit 2; }
  export SCRATCH="${SCRATCH:-$(mktemp -d "${TMPDIR:-/tmp}/peeryard-rig.XXXXXX")}"
  echo "[rig] scratch: $SCRATCH"
  exec unshare -Urmn "${BASH_SOURCE[0]}"
fi

# ---- inner: root in our own user namespace, with our own net and mount namespaces ----
CFG="$RIG_CFG"; HOOK="$RIG_HOOK"; JAR="$RIG_JAR"
# A private magic: a stray connection to any other network is rejected at the first frame.
# Default [112,101,101,114] ("peer"); override with a top-level "magic".
MAGIC="$(jq -c '.magic // [112,101,101,114]' "$CFG")"
RUST_DEVNET_MAGIC='[7,7,7,7]'
# Chain parameters every node must share, chosen by a preset ("chain": "current" | "matrix" | "devnet") or an
# object ({"preset": ..., "blockInterval": ..., "minerRewardDelay": ..., "genesisStateDigestHex": ...}):
#   current (default): a fixed 2 s block-interval target (a pace not tied to any miner's polling rate, so
#                      difficulty retargeting, every 16 blocks (epochLength 16), settles within the first epochs instead of drifting) and a
#                      10-block reward delay so mining rewards are spendable within a run.
#   matrix:            for nodes with sub-blocks (input blocks between ordering blocks): the jar's own block
#                      interval is left alone, since a 2 s ordering-block target would collide with the
#                      sub-block cadence; only the reward delay is shortened.
#   devnet:            nothing overridden (100 ms interval, 720-block reward delay).
#   rust-devnet:       the private devnet the Rust implementations ship with (arkadianet `network = "devnet"`,
#                      ergo-node-rust with its devnet network): magic [7,7,7,7], protocol version 4 from genesis
#                      (networkType devnet60), difficulty 1 with an unreachable epoch boundary, a 20 s block
#                      interval, testnet genesis boxes, 720-block reward delay, no re-emission. Those parameters
#                      are compiled into the Rust binaries, so JVM nodes are configured to match them exactly and
#                      the topology's "magic" must be [7,7,7,7] or absent. The only preset a non-jvm node may use.
# Environment overrides let the caller shape a run without editing the topology: PEERYARD_CHAIN (preset name),
# PEERYARD_MINE_POLL (default polling for miners that set none), PEERYARD_DURATION (seconds; hooks that run
# for a while read it), PEERYARD_KEEP_DATA=1 (do not wipe data dirs on first launch: a devnet that persists).
CHAIN_PRESET="${PEERYARD_CHAIN:-$(jq -r 'if (.chain | type) == "string" then .chain else (.chain.preset // "current") end' "$CFG")}"
DEFAULT_POLL="${PEERYARD_MINE_POLL:-500ms}"
RUST_DEVNET=0
case "$CHAIN_PRESET" in
  current) DEF_INTERVAL="2s"; DEF_DELAY=10 ;;
  matrix)  DEF_INTERVAL="";   DEF_DELAY=10 ;;
  devnet)  DEF_INTERVAL="";   DEF_DELAY="" ;;
  rust-devnet) DEF_INTERVAL=""; DEF_DELAY=""; RUST_DEVNET=1 ;;
  *) echo "FAIL: unknown chain preset '$CHAIN_PRESET' (current | matrix | devnet | rust-devnet)"; exit 2 ;;
esac
BLOCK_INTERVAL="$(jq -r --arg d "$DEF_INTERVAL" 'if (.chain | type) == "object" then (.chain.blockInterval // $d) else $d end' "$CFG")"
REWARD_DELAY="$(jq -r --arg d "$DEF_DELAY" 'if (.chain | type) == "object" then ((.chain.minerRewardDelay // $d) | tostring) else $d end' "$CFG")"
GENESIS_DIGEST="$(jq -r 'if (.chain | type) == "object" then (.chain.genesisStateDigestHex // "") else "" end' "$CFG")"
RUST_MAGIC_OVERRIDE=0
if [[ $RUST_DEVNET == 1 ]]; then
  # The Rust binaries' devnet magic is compiled in as [7,7,7,7]; that is the default here. A topology may set
  # another magic only if every Rust node's binary accepts a devnet magic override (arkadianet `[chain]
  # devnet_magic`, ergo-node-rust `[proxy] magic`, both proposed upstream): the rig then writes the override
  # into each Rust node's config, and a binary without it refuses to start (visible in the node's log).
  if [[ "$(jq -c '.magic // empty' "$CFG")" == "" ]]; then MAGIC="$RUST_DEVNET_MAGIC"
  elif [[ "$MAGIC" != "$RUST_DEVNET_MAGIC" ]]; then RUST_MAGIC_OVERRIDE=1
    echo "[rig] rust-devnet with magic $MAGIC: the Rust nodes get a devnet magic override (needs binaries that accept one)"; fi
  [[ "$BLOCK_INTERVAL$REWARD_DELAY$GENESIS_DIGEST" == "" ]] || { echo "FAIL: chain preset rust-devnet takes no overrides (its parameters are compiled into the Rust nodes)"; exit 2; }
fi
echo "[rig] chain preset $CHAIN_PRESET: blockInterval=${BLOCK_INTERVAL:-jar default} minerRewardDelay=${REWARD_DELAY:-jar default}$([[ $RUST_DEVNET == 1 ]] && echo ' (rust-devnet: 20s, 720, protocol v4, difficulty 1, magic '"$MAGIC"')')"
# JVM launch: `--devnet` loads the jar's devnet.conf (networkType devnet, protocol v3 at genesis, voting for v4).
# rust-devnet launches with no network flag and writes every chain parameter into the node's conf instead, as
# the Rust implementations' own mixed-devnet recipe does (arkadianet scripts/devnet-mixed/genesis.conf).
NET_ARGS="--devnet"; [[ $RUST_DEVNET == 1 ]] && NET_ARGS=""

# The reward delay is part of the emission contract, so it changes the genesis state digest the jar pins (the
# node asserts on it at startup and prints the digest it computed just before refusing). With a delay override
# and no digest given, derive_genesis_digest starts one probe node with the delay, reads that line, and uses it;
# the digest depends on the jar's emission rules, so it is derived per run rather than hard-coded.
derive_genesis_digest(){
  local n="${NODES[0]}" pdir="$SCRATCH/probe" plog="$SCRATCH/probe.log" conf pid d end
  mkdir -p "$pdir/tmp"   # the node copies <network>.conf into java.io.tmpdir at startup and needs it to exist
  conf="$(GENESIS_DIGEST="" SCRATCH_DATA_OVERRIDE="$pdir" gen_conf "$n")"
  ip netns exec "${NS[$n]}" bash -c "cd '${RT_CWD[$n]}' && exec '$JAVA_BIN' $JAVA_OPTS -Djava.io.tmpdir='$pdir/tmp' -jar '${NODE_JAR[$n]}' $NET_ARGS -c '$conf'" > "$plog" 2>&1 &
  pid=$!; end=$((SECONDS + 90)); d=""
  while [[ $SECONDS -lt $end ]]; do
    d="$(grep -oE 'Genesis UTXO state generated with hex digest [0-9a-f]+' "$plog" | head -1 | awk '{print $NF}')"
    [[ -n "$d" ]] && break; kill -0 "$pid" 2>/dev/null || break; sleep 1
  done
  kill -9 "$pid" 2>/dev/null; pkill -9 -f "$conf" 2>/dev/null || true; wait "$pid" 2>/dev/null || true
  [[ -n "$d" ]] || { echo "FAIL: could not derive the genesis digest for minerRewardDelay=$REWARD_DELAY (see $plog)"; exit 2; }
  # Only the probe's own dir goes: node data_$n is never touched here (the probe ran with SCRATCH_DATA_OVERRIDE),
  # so a persisted chain (PEERYARD_KEEP_DATA=1, devnet.sh) survives the probe on every start.
  GENESIS_DIGEST="$d"; rm -rf "$pdir"
  echo "[rig] genesis state digest for minerRewardDelay=$REWARD_DELAY derived from a probe start: ${d:0:16}…"
}
RIG_LOG_DIR="$(jq -r --arg d "$SCRATCH/out" '.log_dir // $d' "$CFG")"
mkdir -p "$SCRATCH" "$RIG_LOG_DIR"
RIG_AFFINITY="$(awk '/^Cpus_allowed_list:/ {print $2}' /proc/$$/status)"   # the CPUs this rig may use (a `taskset` around it narrows them)
mapfile -t NODES < <(jq -r '.nodes[].name' "$CFG")
# Per-node jar (nodes[].jar, else the top-level jar / PEERYARD_JAR; "${VAR}" expanded from the environment), and a
# per-node working directory: the node resolves some fallback configs relative to its CWD, so each node gets its
# own jar's *.conf copies unless the topology names a "runtime_cwd" for all of them.
# KIND[n] = jvm | arkadianet | ergo-node-rust. For a non-jvm node NODE_JAR[n] is its binary (nodes[].bin or the
# kind's PEERYARD_*_BIN variable); everything the rig records about "the jar" (path, sha256) applies to it.
declare -A NODE_JAR RT_CWD KIND
# shellcheck disable=SC2016  # a jq program: $ENV is jq's, not the shell's
JAR_XP='def xp: if type == "string" then gsub("\\$\\{(?<v>[A-Za-z_][A-Za-z0-9_]*)\\}"; ($ENV[.v] // "")) else . end;'
RUNTIME_CWD="$(jq -r '.runtime_cwd // empty' "$CFG")"
for n in "${NODES[@]}"; do
  KIND[$n]="$(jq -r --arg n "$n" 'first(.nodes[]|select(.name==$n).kind) // "jvm"' "$CFG")"
  if [[ "${KIND[$n]}" == jvm ]]; then
    j="$(jq -r --arg n "$n" "$JAR_XP"' first(.nodes[]|select(.name==$n).jar // empty) | xp' "$CFG")"
    NODE_JAR[$n]="$(readlink -f "${j:-$JAR}")"
    [[ -f "${NODE_JAR[$n]}" ]] || { echo "FAIL: no jar for node $n (${j:-$JAR})"; exit 2; }
    if [[ -n "$RUNTIME_CWD" ]]; then RT_CWD[$n]="$RUNTIME_CWD"
    else
      RT_CWD[$n]="$SCRATCH/rt_$n"; mkdir -p "${RT_CWD[$n]}/src/main/resources"
      unzip -o -q "${NODE_JAR[$n]}" application.conf devnet.conf mainnet.conf testnet.conf -d "${RT_CWD[$n]}/src/main/resources"
    fi
  else
    [[ $RUST_DEVNET == 1 ]] || { echo "FAIL: node $n is kind ${KIND[$n]}; a non-jvm node needs the chain preset rust-devnet (its chain parameters are compiled in)"; exit 2; }
    b="$(jq -r --arg n "$n" "$JAR_XP"' first(.nodes[]|select(.name==$n).bin // empty) | xp' "$CFG")"
    if [[ -z "$b" ]]; then case "${KIND[$n]}" in arkadianet) b="${PEERYARD_ARKADIANET_BIN:-}" ;; ergo-node-rust) b="${PEERYARD_ERGO_NODE_RUST_BIN:-}" ;; esac; fi
    NODE_JAR[$n]="$(readlink -f "$b")"; RT_CWD[$n]="$SCRATCH/rt_$n"; mkdir -p "${RT_CWD[$n]}"
    [[ -x "${NODE_JAR[$n]}" ]] || { echo "FAIL: no binary for node $n (kind ${KIND[$n]}): '$b'"; exit 2; }
  fi
done

# make /run writable in our mount namespace so `ip netns` can create its bind mounts
mount --make-rprivate / 2>/dev/null || true
mount -t tmpfs tmpfs /run || { echo "FAIL: tmpfs /run (user-namespace mount)"; exit 10; }
mkdir -p /run/netns

declare -A NS IP P2P REST LIP LINK_OF PRIMARY_IP CONFIGURED VETH PARTITIONED NODE_OF_IP ID_IP
declare -a LINK_A LINK_B
# Identity addresses: every node has one address, ID_IP (100.64.0.k, outside the site-local ranges), on its loopback,
# reachable only from the nodes it shares a link with (a /32 route per link, no forwarding), and used as its
# declared address and as the address its peers dial. The per-link /30 addresses alone are site-local, and a node
# on a site-local network advertises the address of the link it connected over (the node's LAN preference), which
# its other peers cannot reach: a node learned through gossip was then dialled at an unreachable address.
nid=0
for n in "${NODES[@]}"; do
  [[ "$n" =~ ^[A-Za-z0-9]{1,5}$ ]] || { echo "FAIL: node name '$n' must be 1-5 letters or digits (veth names are ve_<a>_<b>, at most 15 characters)"; exit 2; }
  NS[$n]="ns_$n"
  P2P[$n]=$(jq -r --arg n "$n" 'first(.nodes[]|select(.name==$n).p2p) // 9021' "$CFG")
  REST[$n]=$(jq -r --arg n "$n" 'first(.nodes[]|select(.name==$n).rest) // 9052' "$CFG")
  ip netns add "${NS[$n]}"
  ip netns exec "${NS[$n]}" ip link set lo up
  nid=$((nid + 1)); ID_IP[$n]="100.64.0.$nid"; NODE_OF_IP["${ID_IP[$n]}"]="$n"
  ip -n "${NS[$n]}" addr add "${ID_IP[$n]}/32" dev lo
done

# Links: one veth pair per link, each on its own /30, so a node on several links is multi-homed with one IP per
# link. LIP[node,i] = the node's IP on link i; LINK_OF[x,y] = the link between x and y; PRIMARY_IP[node] = the IP
# on its first link. The declared and dialled address is the node's identity address (ID_IP, above). netem is applied per direction.
nlinks=$(jq '.links|length' "$CFG")
for ((i=0;i<nlinks;i++)); do
  a=$(jq -r ".links[$i].a" "$CFG"); b=$(jq -r ".links[$i].b" "$CFG")
  sub="10.9.$((20+i))"; aip="$sub.1"; bip="$sub.2"
  va="ve_${a}_${b}"; vb="ve_${b}_${a}"
  ip link add "$va" type veth peer name "$vb"
  ip link set "$va" netns "${NS[$a]}"; ip link set "$vb" netns "${NS[$b]}"
  ip -n "${NS[$a]}" addr add "$aip/30" dev "$va"
  ip -n "${NS[$b]}" addr add "$bip/30" dev "$vb"
  ip -n "${NS[$a]}" link set "$va" up; ip -n "${NS[$b]}" link set "$vb" up
  # each end reaches the other's identity over this link, from its own identity
  ip -n "${NS[$a]}" route add "${ID_IP[$b]}/32" via "$bip" src "${ID_IP[$a]}"
  ip -n "${NS[$b]}" route add "${ID_IP[$a]}/32" via "$aip" src "${ID_IP[$b]}"
  LIP["$a,$i"]="$aip"; LIP["$b,$i"]="$bip"; NODE_OF_IP["$aip"]="$a"; NODE_OF_IP["$bip"]="$b"
  LINK_OF["$a,$b"]=$i; LINK_OF["$b,$a"]=$i
  [[ -z "${PRIMARY_IP[$a]:-}" ]] && PRIMARY_IP[$a]="$aip"
  [[ -z "${PRIMARY_IP[$b]:-}" ]] && PRIMARY_IP[$b]="$bip"
  # netem spec per direction from the link's fields: delay_ms [jitter_ms] loss_pct rate_kbit, with optional
  # per-direction overrides delay_ms_ab / delay_ms_ba (and loss_pct_ab, jitter_ms_ab, rate_kbit_ab, ...): a -> b
  # uses the _ab value when present, b -> a the _ba value, else the symmetric field. jitter needs delay > 0.
  spec_for(){ local dir="$1" f d l j r s=""   # dir = ab | ba
    d=$(jq -r ".links[$i] | .delay_ms_$dir // .delay_ms // 0" "$CFG"); l=$(jq -r ".links[$i] | .loss_pct_$dir // .loss_pct // 0" "$CFG")
    j=$(jq -r ".links[$i] | .jitter_ms_$dir // .jitter_ms // 0" "$CFG"); r=$(jq -r ".links[$i] | .rate_kbit_$dir // .rate_kbit // 0" "$CFG")
    [[ "$d" != "0" ]] && { s="delay ${d}ms"; [[ "$j" != "0" ]] && s="$s ${j}ms"; }
    [[ "$l" != "0" ]] && s="$s loss ${l}%"
    [[ "$r" != "0" ]] && s="$s rate ${r}kbit"
    echo "$s"; }
  spec_ab="$(spec_for ab)"; spec_ba="$(spec_for ba)"
  CONFIGURED["$a,$b"]="$spec_ab"; CONFIGURED["$b,$a"]="$spec_ba"   # heal restores these
  if [[ -n "$spec_ab" ]]; then ip netns exec "${NS[$a]}" tc qdisc add dev "$va" root netem $spec_ab \
    || { echo "FAIL: netem '$spec_ab' on $a->$b not applied (is sch_netem available?)"; exit 10; }; fi
  if [[ -n "$spec_ba" ]]; then ip netns exec "${NS[$b]}" tc qdisc add dev "$vb" root netem $spec_ba \
    || { echo "FAIL: netem '$spec_ba' on $b->$a not applied (is sch_netem available?)"; exit 10; }; fi
  LINK_A[i]="$a"; LINK_B[i]="$b"
  VETH["$a,$b"]="$va"; VETH["$b,$a"]="$vb"
done
for n in "${NODES[@]}"; do IP[$n]="${ID_IP[$n]}"; done   # declared and dialled; PRIMARY_IP stays the first link's /30 address

# ---- each node's HOCON overlay, and launch ----
# PID: live pid per node. MINING_OVR / POLL_OVR: runtime overrides set by the mining helpers (empty = the topology's
# value). FRESH_DONE: the data dir is wiped on a node's first launch only, so a relaunch keeps its chain.
declare -A PID MINING_OVR POLL_OVR FRESH_DONE CONF_OVR
# The chain parameters of the rust-devnet preset, for a JVM node: the values of arkadianet's
# scripts/devnet-mixed/genesis.conf (its Rust counterpart is ChainSpec::devnet()), which ergo-node-rust's devnet
# network mirrors. networkType devnet60 selects the protocol-v4 launch parameters (Devnet60LaunchParameters).
jvm_rust_devnet_conf(){
  cat <<'EOF'
ergo.networkType="devnet60"
ergo.chain.protocolVersion=4
ergo.chain.addressPrefix=16
ergo.chain.initialDifficultyHex="01"
ergo.chain.epochLength=33554432
ergo.chain.blockInterval=20s
ergo.chain.genesisStateDigestHex="cb63aa99a3060f341781d8662b58bf18b9ad258db4fe88d09f8f71cb668cad4502"
ergo.chain.monetary.minerRewardDelay=720
ergo.chain.voting.votingLength=33554432
ergo.chain.voting.softForkEpochs=32
ergo.chain.voting.activationEpochs=32
ergo.chain.voting.version2ActivationHeight=2147483647
ergo.chain.voting.version2ActivationDifficultyHex="20"
ergo.chain.reemission.checkReemissionRules=false
ergo.chain.reemission.activationHeight=100000001
ergo.wallet.secretStorage.secretDir=${ergo.directory}"/wallet/keystore"
EOF
}
# knownPeers of a node as "ip:port" strings, one per line, each peer dialled at its identity address
known_peer_addrs(){ local n="$1" pn
  jq -r --arg n "$n" '.nodes[]|select(.name==$n).knownPeers[]?' "$CFG" | while read -r pn; do
    [[ -z "$pn" ]] && continue
    echo "${IP[$pn]}:${P2P[$pn]}"; done; }
# TOML for an arkadianet node (docs/configuration.md of arkadianet/ergo; the values of its scripts/devnet-mixed/
# rust-node.toml with the rig's addresses). Mining stays off: the binary has no internal miner
# (use_external_miner must be true), so a mining arkadianet node needs a solver loop against /mining/*.
gen_conf_arkadianet(){ local n="$1"; local f="$SCRATCH/conf_$n.toml" dir="$SCRATCH/data_$n" kp extra mining
  mkdir -p "$dir"
  mining="${MINING_OVR[$n]:-$(jq -r --arg n "$n" 'first(.nodes[]|select(.name==$n).mining) // false' "$CFG")}"
  kp="$(known_peer_addrs "$n" | sed 's/.*/"&"/' | paste -sd, -)"
  extra="$(jq -r --arg n "$n" '.nodes[]|select(.name==$n).conf // {} | to_entries[]? | "\(.key) = \(.value)"' "$CFG")"
  {
    echo 'network = "devnet"'
    echo "data_dir = \"$dir\""
    [[ $RUST_MAGIC_OVERRIDE == 1 ]] && { echo '[chain]'; echo "devnet_magic = $MAGIC"; }
    echo '[node]'; echo "node_name = \"$n\""; echo 'agent_name = "ergo-rust"'
    echo '[peers]'; echo "known = [$kp]"; echo "bind_addr = \"0.0.0.0:${P2P[$n]}\""; echo "declared_addr = \"${IP[$n]}:${P2P[$n]}\""
    echo 'allow_local = true'
    echo '[sync]'; echo 'sync_interval_secs = 1'; echo 'sync_interval_stable_secs = 1'
    echo '[api]'; echo "bind = \"127.0.0.1:${REST[$n]}\""
    echo '[api.security]'; echo "api_key_hash = \"$API_KEY_HASH\""
    # "mining": true serves candidates on /mining/* for an external solver (solve_start); rewards go to the
    # public test key below (secret scalar 1, the key the node's own mixed-devnet recipe uses)
    if [[ "$mining" == "true" ]]; then
      echo '[mining]'; echo 'enabled = true'; echo 'use_external_miner = true'; echo "miner_public_key_hex = \"$SOLVER_PK\""
    fi
    while IFS= read -r line; do [[ -n "$line" ]] && echo "$line"; done <<< "$extra"
    [[ -n "${CONF_OVR[$n]:-}" ]] && printf '%s\n' "${CONF_OVR[$n]}"
  } > "$f"; echo "$f"; }
# TOML for an ergo-node-rust node (its ergo.toml.example): [proxy] network selects the chain; the node binary
# takes the config path as its argument.
gen_conf_ergo_node_rust(){ local n="$1"; local f="$SCRATCH/conf_$n.toml" dir="$SCRATCH/data_$n" kp extra
  mkdir -p "$dir"
  kp="$(known_peer_addrs "$n" | sed 's/.*/"&"/' | paste -sd, -)"
  extra="$(jq -r --arg n "$n" '.nodes[]|select(.name==$n).conf // {} | to_entries[]? | "\(.key) = \(.value)"' "$CFG")"
  {
    echo '[proxy]'; echo 'network = "devnet"'
    [[ $RUST_MAGIC_OVERRIDE == 1 ]] && echo "magic = $MAGIC"
    echo '[listen.ipv4]'; echo "address = \"0.0.0.0:${P2P[$n]}\""; echo 'mode = "full"'; echo 'max_inbound = 20'
    echo '[outbound]'; echo 'min_peers = 1'; echo 'max_peers = 10'; echo "seed_peers = [$kp]"
    echo '[identity]'; echo 'agent_name = "ergo-node-rust"'; echo "peer_name = \"$n\""; echo 'protocol_version = "6.0.3"'
    echo '[node]'; echo "data_dir = \"$dir\""; echo 'state_type = "utxo"'; echo 'blocks_to_keep = -1'
    echo "api_address = \"127.0.0.1:${REST[$n]}\""
    while IFS= read -r line; do [[ -n "$line" ]] && echo "$line"; done <<< "$extra"
    [[ -n "${CONF_OVR[$n]:-}" ]] && printf '%s\n' "${CONF_OVR[$n]}"
  } > "$f"; echo "$f"; }
gen_conf() {  # $1 = node name -> prints the conf path (SCRATCH_DATA_OVERRIDE: a throwaway data dir for the digest probe)
  local n="$1"; local f="$SCRATCH/conf_$n.conf" dir="${SCRATCH_DATA_OVERRIDE:-$SCRATCH/data_$n}"
  case "${KIND[$n]:-jvm}" in arkadianet) gen_conf_arkadianet "$n"; return ;; ergo-node-rust) gen_conf_ergo_node_rust "$n"; return ;; esac
  [[ -n "${SCRATCH_DATA_OVERRIDE:-}" ]] && f="$SCRATCH_DATA_OVERRIDE/conf_$n.conf"
  mkdir -p "$dir"
  local mining kp extra poll
  mining="${MINING_OVR[$n]:-$(jq -r --arg n "$n" 'first(.nodes[]|select(.name==$n).mining) // false' "$CFG")}"
  # mining rate: runtime override > per-node "mine_poll" > 500ms. A large mine_poll (e.g. "45s") leaves the
  # miner idle between rare blocks, without a restart.
  poll="${POLL_OVR[$n]:-$(jq -r --arg n "$n" --arg d "$DEFAULT_POLL" 'first(.nodes[]|select(.name==$n).mine_poll) // $d' "$CFG")}"
  # knownPeers names -> "ip:p2p", dialing each peer at its identity address
  kp="$(jq -r --arg n "$n" '.nodes[]|select(.name==$n).knownPeers[]?' "$CFG" | while read -r pn; do
        [[ -z "$pn" ]] && continue
        printf '"%s:%s",' "${IP[$pn]}" "${P2P[$pn]}"; done)"
  kp="[${kp%,}]"
  # extra HOCON lines, given per node as {"dotted.key": "value"}
  extra="$(jq -r --arg n "$n" '.nodes[]|select(.name==$n).conf // {} | to_entries[]? | "\(.key)=\(.value)"' "$CFG")"
  {
    echo "ergo.directory=\"$dir\""
    echo "ergo.node.mining=$mining"
    echo "ergo.node.offlineGeneration=$mining"
    echo "ergo.node.useExternalMiner=false"
    [[ "$mining" == "true" ]] && echo "ergo.node.internalMinerPollingInterval=$poll"
    echo "ergo.wallet.testMnemonic=\"$MNEMONIC\""
    echo "ergo.wallet.testKeysQty=5"
    echo "scorex.network.bindAddress=\"0.0.0.0:${P2P[$n]}\""
    echo "scorex.network.declaredAddress=\"${IP[$n]}:${P2P[$n]}\""
    echo "scorex.network.knownPeers=$kp"
    echo "scorex.network.allowLocal=true"
    echo "scorex.network.localOnly=true"   # the same switch under its older name (releases before v6.0.3 read only this; later ones ignore it)
    echo "scorex.network.nodeName=\"$n\""
    echo "scorex.restApi.bindAddress=\"127.0.0.1:${REST[$n]}\""
    echo "scorex.restApi.apiKeyHash=\"$API_KEY_HASH\""
    echo "scorex.network.magicBytes=$MAGIC"
    # Devnet settings matched to the node's own integration-test template (src/it/resources/devnetTemplate.conf),
    # so that a sole-peer follower fully syncs and a restarted node keeps its chain (rig/examples/floor.*).
    echo "ergo.node.stateType=utxo"
    echo "ergo.node.verifyTransactions=true"
    echo "ergo.node.blocksToKeep=-1"
    echo "ergo.node.mempoolCapacity=10000"
    echo "ergo.chain.powScheme.powType=autolykos"
    echo "ergo.chain.powScheme.k=32"
    echo "ergo.chain.powScheme.n=26"
    [[ $RUST_DEVNET == 1 ]] && jvm_rust_devnet_conf
    [[ -n "$BLOCK_INTERVAL" ]] && echo "ergo.chain.blockInterval=$BLOCK_INTERVAL"
    [[ -n "$REWARD_DELAY" ]] && echo "ergo.chain.monetary.minerRewardDelay=$REWARD_DELAY"
    [[ -n "$GENESIS_DIGEST" ]] && echo "ergo.chain.genesisStateDigestHex=\"$GENESIS_DIGEST\""
    while IFS= read -r line; do [[ -n "$line" ]] && echo "$line"; done <<< "$extra"
    # runtime HOCON lines set by the hook before a deferred launch, e.g. a genesisId pin
    [[ -n "${CONF_OVR[$n]:-}" ]] && printf '%s\n' "${CONF_OVR[$n]}"
  } > "$f"
  echo "$f"
}

launch() {
  local n="$1" conf
  # refuse a malformed genesis pin (the node would start and never sync); see genesis_id
  if [[ "${CONF_OVR[$n]:-}" =~ genesisId=\"([^\"]*)\" ]] && ! [[ "${BASH_REMATCH[1]}" =~ ^[0-9a-f]{64}$ ]]; then
    echo "[rig] refusing to launch $n: genesisId pin '${BASH_REMATCH[1]}' is not a 64-hex block id"; return 1; fi
  # Wipe the data dir on the node's first launch only. This must run in this shell, not in the $(gen_conf)
  # subshell, or FRESH_DONE would never be recorded and every relaunch would wipe the chain.
  if [[ -z "${FRESH_DONE[$n]:-}" ]]; then [[ "${PEERYARD_KEEP_DATA:-0}" == 1 ]] || rm -rf "$SCRATCH/data_$n"; FRESH_DONE[$n]=1; fi
  conf="$(gen_conf "$n")"
  echo "==== [rig] (re)launch $n $(date -Iseconds) kind=${KIND[$n]} jar=$(basename "${NODE_JAR[$n]}") mining=${MINING_OVR[$n]:-cfg} poll=${POLL_OVR[$n]:-cfg} ====" >> "$RIG_LOG_DIR/node_$n.log"
  case "${KIND[$n]}" in
    jvm)
      # Per-node java.io.tmpdir: at startup the node copies <network>.conf from its jar into tmpdir and deletes it
      # on exit, so nodes sharing one tmpdir can read each other's network type.
      mkdir -p "$SCRATCH/tmp_$n"
      ip netns exec "${NS[$n]}" bash -c "cd '${RT_CWD[$n]}' && exec '$JAVA_BIN' $JAVA_OPTS -Djava.io.tmpdir='$SCRATCH/tmp_$n' -jar '${NODE_JAR[$n]}' $NET_ARGS -c '$conf'" \
        >> "$RIG_LOG_DIR/node_$n.log" 2>&1 & ;;
    arkadianet)
      ip netns exec "${NS[$n]}" bash -c "cd '${RT_CWD[$n]}' && exec '${NODE_JAR[$n]}' --config '$conf'" >> "$RIG_LOG_DIR/node_$n.log" 2>&1 & ;;
    ergo-node-rust)
      ip netns exec "${NS[$n]}" bash -c "cd '${RT_CWD[$n]}' && exec '${NODE_JAR[$n]}' '$conf'" >> "$RIG_LOG_DIR/node_$n.log" 2>&1 & ;;
  esac
  PID[$n]=$!
  echo "[rig] launched $n (ns=${NS[$n]} ip=${IP[$n]} p2p=${P2P[$n]} rest=${REST[$n]} kind=${KIND[$n]} jar=$(basename "${NODE_JAR[$n]}") pid=${PID[$n]})"
}

# ---- helpers for the hook ----
rest()   { ip netns exec "${NS[$1]}" curl -s --max-time 4 "http://127.0.0.1:${REST[$1]}$2"; }
node_ip(){ echo "${IP[$1]}"; }
applied_header(){ rest "$1" /info | jq -r '.bestFullHeaderId // .bestHeaderId // empty'; }
# genesis_id <node> [timeout s, default 60]: the node's block id at height 1, once it answers with a well-formed id
# (64 hex characters); prints it, or nothing with status 1. A genesisId pin must never be empty or malformed: the
# node accepts genesisId = "" at startup (it only checks that the key is present) and then rejects every NiPoPoW
# proof as WrongGenesis; right after a relaunch, REST answers before the chain is reloaded and height 1 reads empty.
genesis_id(){ local n="$1" end=$((SECONDS + ${2:-60})) g
  while [[ $SECONDS -lt $end ]]; do g="$(header_at "$n" 1)"; [[ "$g" =~ ^[0-9a-f]{64}$ ]] && { echo "$g"; return 0; }; sleep 1; done
  return 1; }
header_at(){ rest "$1" "/blocks/at/$2" | jq -r '.[0] // empty'; }
full_height(){ rest "$1" /info | jq -r '.fullHeight // 0'; }
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
# harness_fail MSG: a rig helper did not do what it was asked (a netem change, a crash, a relaunch). The run cannot
# show what the hook claims, whatever it prints, so the rig's verdict becomes INCONCLUSIVE (cause HARNESS).
HARNESS_FAIL=()
harness_fail(){ HARNESS_FAIL+=("$1"); echo "[rig] HARNESS-FAIL $1"; }
link_netem(){ # $1=a $2=b $3=netem spec; replaces the a->b egress qdisc on a's veth
  have_link "$1" "$2" || { echo "[rig] no link $1<->$2" >&2; return 1; }
  local dev="${VETH["$1,$2"]}"
  ip netns exec "${NS[$1]}" tc qdisc replace dev "$dev" root netem $3 \
    || { harness_fail "netem '$3' on $1->$2 not applied"; return 1; }
}
# partition A B: drop 100% both directions (a soft cut that keeps the TCP sockets, unlike unplugging the link).
partition(){ have_link "$1" "$2" || { harness_fail "partition $1 $2: no such link"; return 1; }
  link_netem "$1" "$2" "loss 100%" && link_netem "$2" "$1" "loss 100%" || return 1; PARTITIONED["$1,$2"]=1; PARTITIONED["$2,$1"]=1; echo "[rig] partition $1<->$2 (100% loss)"; }
# heal A B: restore the link's configured shaping (delay/loss/jitter/rate), both directions; clean if it had none.
heal(){ have_link "$1" "$2" || { harness_fail "heal $1 $2: no such link"; return 1; }
  link_netem "$1" "$2" "${CONFIGURED["$1,$2"]}" && link_netem "$2" "$1" "${CONFIGURED["$2,$1"]}" || return 1; unset 'PARTITIONED[$1,$2]' 'PARTITIONED[$2,$1]'; echo "[rig] heal $1<->$2"; }
# ---- state and peer oracles ----
# same_state A B: the UTXO state root at the tip, compared only when both nodes are at the same full height
# (roots differ by height): SAME@h:root / DIFF@h:A=..:B=.. / NOHEIGHT, or, when the heights differ,
# LAG@ha,hb <label>: the lower node's best full-block header id against the higher node's header id at that
# height (/blocks/at/h, first entry, as same_chain reads it): "same-chain" (behind on the same chain), "fork"
# (different ids at the lower height), "unknown" (an id could not be read). The label follows a space, so callers
# that cut at ':' or match LAG@* are unaffected.
# same_input_chain A B (Matrix line: sub-blocks): the best input-block chain since the best ordering block, from
# /blocks/bestInputChain ({bestOrdering: header id, bestInputBlocks: [ids]}), compared between two nodes:
#   SAME@<ordering>:<n>              same ordering tip and the same n input-block ids (n may be 0)
#   PREFIX@<ordering>:A=<na>:B=<nb>  same ordering tip; the shorter chain is a prefix of the longer (one node is behind)
#   DIFF@<ordering>:A=<na>:B=<nb>    same ordering tip, different input chains (an input-block fork)
#   DIFF-ORD@<a>/<b>                 different ordering tips (compare only after pausing the miner and settling)
#   NONE                             a node did not answer, or has no such route (a mainline jar)
# Under a live miner two readings are rarely of the same moment (an input block about once a second): use
# same_input_chain_stable.
same_input_chain(){ _cmp_input_chain "$(rest "$1" /blocks/bestInputChain)" "$(rest "$2" /blocks/bestInputChain)"; }
# _cmp_input_chain <reply A> <reply B>: /blocks/bestInputChain lists the input chain TIP FIRST (the node reverses its
# root-first best chain, InputBlocksProcessor.bestInputBlocksChain), so a node that is behind on the same chain holds
# the leader's list without its first entries: PREFIX (behind on the same chain) is a suffix match of the lists.
_cmp_input_chain(){ local ra="$1" rb="$2" oa ob
  oa=$(jq -r '.bestOrdering // empty' <<< "$ra" 2>/dev/null); ob=$(jq -r '.bestOrdering // empty' <<< "$rb" 2>/dev/null)
  if [[ -z "$oa" || -z "$ob" ]]; then echo NONE; return; fi
  if [[ "$oa" != "$ob" ]]; then echo "DIFF-ORD@${oa:0:8}/${ob:0:8}"; return; fi
  jq -rn --argjson a "$(jq -c '.bestInputBlocks // []' <<< "$ra")" --argjson b "$(jq -c '.bestInputBlocks // []' <<< "$rb")" --arg o "${oa:0:8}" '
    ($a | length) as $na | ($b | length) as $nb
    | if $a == $b then "SAME@\($o):\($na)"
      elif ($na < $nb and $b[($nb - $na):] == $a) or ($nb < $na and $a[($na - $nb):] == $b) then "PREFIX@\($o):A=\($na):B=\($nb)"
      else "DIFF@\($o):A=\($na):B=\($nb)" end'; }
# same_input_chain_stable A B [tries, default 60]: same_input_chain without pausing A's miner (a restart may drop an
# in-memory input chain): read A, then B, then A again, and compare only when A did not change in between; retried
# (0.5 s apart) until the readings agree (SAME) or the tries run out, printing the last comparison.
same_input_chain_stable(){ local i ra1 rb ra2 r=NONE
  for ((i=0; i<${3:-60}; i++)); do
    ra1=$(rest "$1" /blocks/bestInputChain); rb=$(rest "$2" /blocks/bestInputChain); ra2=$(rest "$1" /blocks/bestInputChain)
    if [[ -n "$ra1" && "$ra1" == "$ra2" ]]; then r=$(_cmp_input_chain "$ra1" "$rb"); [[ "$r" == SAME@* ]] && break; fi
    sleep 0.5
  done; echo "$r"; }
# input_block_txids <node> <input block id>: the transaction ids of one input block (Matrix line)
# (the route answers 404 with an error object when the node holds no transaction list for that block: nothing)
input_block_txids(){ rest "$1" "/blocks/$2/inputBlockTransactionIds" | jq -r 'if type == "array" then .[] else empty end' 2>/dev/null; }
# input_chain_ids <node>: the node's best input-block chain, one id per line
input_chain_ids(){ rest "$1" /blocks/bestInputChain | jq -r '.bestInputBlocks[]? // empty' 2>/dev/null; }
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
# peers_of A: the names of A's connected peers. Rig nodes name themselves after their topology name, and an
# implementation may report a peer under its own label instead (ergo-node-rust lists a JVM peer as "ergoref"),
# so an entry whose name is not a rig node is resolved by the IP in its address (one IP per node per link).
peers_of(){ local name addr ip n
  rest "$1" /peers/connected | jq -r '.[]? | [(.name // ""), (.address // "")] | @tsv' 2>/dev/null | while IFS=$'\t' read -r name addr; do
    n=""; for x in "${NODES[@]}"; do [[ "$name" == "$x" ]] && n="$x"; done
    if [[ -z "$n" ]]; then ip="${addr#/}"; ip="${ip%%:*}"; n="${NODE_OF_IP[$ip]:-}"; fi
    [[ -n "$n" ]] && echo "$n"; done | sort -u | tr '\n' ' '; }
# check_topology: every link that is not partitioned must show up as a connection on both ends, and no node
# may be connected to a node it has no link to. A node with knownPeers [] is inbound-only and is still expected
# to be connected over its links (the other side dials it). Prints one line per link; returns 1 on any mismatch.
# check_topology_wait [timeout s, default 60]: check_topology, retried quietly until it holds or the time runs out
# (a node restarted by stop_mining/start_mining needs a few seconds to reconnect), then printed once
check_topology_wait(){ local end=$((SECONDS + ${1:-60})); while [[ $SECONDS -lt $end ]]; do check_topology >/dev/null && break; sleep 3; done; check_topology; }
check_topology(){ local i a b pa pb ok=0 n p
  for i in "${!LINK_A[@]}"; do a="${LINK_A[$i]}"; b="${LINK_B[$i]}"
    if [[ -n "${PARTITIONED["$a,$b"]:-}" ]]; then echo "  link $a<->$b: partitioned (not expected connected)"; continue; fi
    pa=" $(peers_of "$a")"; pb=" $(peers_of "$b")"
    if [[ "$pa" == *" $b "* && "$pb" == *" $a "* ]]; then echo "  link $a<->$b: connected both ways"
    else echo "  link $a<->$b: MISSING ($a sees:${pa% } | $b sees:${pb% })"; ok=1; fi
  done
  for n in "${NODES[@]}"; do for p in $(peers_of "$n"); do
    [[ -n "${LINK_OF["$n,$p"]:-}" ]] || { echo "  node $n: connected to $p WITHOUT a link"; ok=1; }; done; done
  return $ok; }
# orphans_between A h0 h1: header ids beyond the first at each height in [h0, h1] as node A knows them (siblings
# mined and later abandoned); a measure of how often latency produced competing blocks.
orphans_between(){ local n=$1 h t=0 k
  for ((h = $2; h <= $3; h++)); do k=$(rest "$n" "/blocks/at/$h" | jq -r 'length' 2>/dev/null); t=$((t + ${k:-1} - 1)); done; echo "$t"; }
# rss_mb A / data_mb A: the node's resident memory and its data directory on disk, in MB
rss_mb(){ local p="${PID[$1]:-}"; [[ -n "$p" ]] && ps -o rss= -p "$p" 2>/dev/null | awk '{printf "%d", $1/1024}' || echo 0; }
data_mb(){ du -sm "$SCRATCH/data_$1" 2>/dev/null | cut -f1; }
# crash NODE: SIGKILL it (not a graceful stop) and leave it down. revive NODE brings it back with its chain.
crash(){ local n="$1"; local p="${PID[$n]:-}"
  [[ -n "$p" ]] && { kill -9 "$p" 2>/dev/null; }
  pkill -9 -f "$SCRATCH/conf_${n}\.(conf|toml)" 2>/dev/null || true
  [[ -n "$p" ]] && wait "$p" 2>/dev/null || true
  local t; for t in 1 2 3 4 5 6 7 8 9 10; do pgrep -f "$SCRATCH/conf_${n}\.(conf|toml)" >/dev/null 2>&1 || break; sleep 1; done
  pgrep -f "$SCRATCH/conf_${n}\.(conf|toml)" >/dev/null 2>&1 && harness_fail "crash $n: its process still runs after SIGKILL"
  PID[$n]=""; echo "[rig] crash $n (SIGKILL, left down)"; }
revive(){ echo "[rig] revive $1"; launch "$1"; wait_up "$1"; }
wait_up(){ # $1=node: wait up to PEERYARD_UP_TIMEOUT s (default 60) for its REST API
  local n="$1" end=$((SECONDS + ${PEERYARD_UP_TIMEOUT:-60}))
  while [[ $SECONDS -lt $end ]]; do
    rest "$n" /info | jq -e '.appVersion' >/dev/null 2>&1 && { echo "[rig] $n REST up"; return 0; }
    sleep 2
  done
  echo "[rig] WARN $n never came up"; return 1
}

# ---- wallet and transactions ----
# Every node's wallet is initialized and unlocked from its testMnemonic (the rig's default, or a per-node
# "conf" override of ergo.wallet.testMnemonic so two nodes hold different keys). A miner's rewards land in its
# wallet and become spendable after REWARD_DELAY blocks. Amounts are nanoERG.
API_KEY=hello
wallet(){ # wallet <node> <path> [json body]: the wallet API with the key; GET without a body, POST with one
  local n="$1" p="$2" body="${3:-}"
  if [[ -n "$body" ]]; then
    ip netns exec "${NS[$n]}" curl -s --max-time 10 -X POST -H "api_key: $API_KEY" -H 'Content-Type: application/json' \
      --data "$body" "http://127.0.0.1:${REST[$n]}$p"
  else ip netns exec "${NS[$n]}" curl -s --max-time 10 -H "api_key: $API_KEY" "http://127.0.0.1:${REST[$n]}$p"; fi; }
address(){ wallet "$1" /wallet/addresses | jq -r '.[0] // empty'; }
balance(){ wallet "$1" /wallet/balances | jq -r '.balance // 0'; }
# pay <from> <to> <nanoerg>: one payment from <from>'s wallet to <to>'s first address; prints the tx id, or the
# node's error text (so a rejected payment is visible, not silent)
pay(){ local to; to="$(address "$2")"; [[ -n "$to" ]] || { echo "no address for $2"; return 1; }
  wallet "$1" /wallet/payment/send "[{\"address\":\"$to\",\"value\":$3}]" | jq -r 'if type == "string" then . else (.detail // .reason // tojson) end'; }
wait_balance(){ # wait_balance <node> <min nanoerg> [timeout s, default 240]: prints the balance reached
  local end=$((SECONDS + ${3:-240})) b=0
  while [[ $SECONDS -lt $end ]]; do b=$(balance "$1"); [[ "${b:-0}" -ge "$2" ]] && { echo "$b"; return 0; }; sleep 2; done
  echo "${b:-0}"; return 1; }
block_txs(){ # block_txs <node> <height>: transactions in the block at <height> as that node holds it (coinbase included)
  local id; id=$(header_at "$1" "$2"); [[ -n "$id" ]] || { echo 0; return; }
  rest "$1" "/blocks/$id" | jq -r '.blockTransactions.transactions | length' 2>/dev/null || echo 0; }
# mempool_ids <node>: the unconfirmed-pool transaction ids, in the order the node lists them; mempool_size counts them.
mempool_ids(){ rest "$1" "/transactions/unconfirmed?limit=10000" | jq -r '.[]?.id // empty' 2>/dev/null; }
mempool_size(){ rest "$1" "/transactions/unconfirmed?limit=10000" | jq -r 'length' 2>/dev/null || echo 0; }
# send_fee <from> <to> <nanoerg> <fee>: one payment with an explicit fee (nanoERG) through /wallet/transaction/send,
# whose request holder carries "fee" (the default fee otherwise: ergo.wallet.defaultTransactionFee). Prints the
# tx id, or the node's error text.
send_fee(){ local to; to="$(address "$2")"; [[ -n "$to" ]] || { echo "no address for $2"; return 1; }
  wallet "$1" /wallet/transaction/send "{\"requests\":[{\"address\":\"$to\",\"value\":$3}],\"fee\":$4}" \
    | jq -r 'if type == "string" then . else (.detail // .reason // tojson) end'; }
# mint_boxes <node> <txs> <outputs> [nanoerg]: grow the UTXO set. Each transaction pays <outputs> separate
# outputs (default 1,000,000 nanoERG each) to the node's own first address, in batches of 10 transactions that
# are left to confirm before the next batch (a long unconfirmed chain of self-payments is what the wallet would
# otherwise build). Prints "minted <accepted>/<txs> txs, <boxes> outputs". A UTXO-set snapshot has chunks to
# download only once the set has more than about 2^14 boxes (manifest depth 14), so this is what makes the
# snapshot path exercisable on a devnet.
mint_boxes(){ local n="$1" txs="$2" outs="$3" amt="${4:-1000000}"; local to reqs i acc=0 out end
  to="$(address "$n")"; [[ -n "$to" ]] || { echo "no address for $n"; return 1; }
  reqs="$(jq -n -c --arg a "$to" --argjson v "$amt" --argjson k "$outs" '[range($k) | {address: $a, value: $v}]')"
  for ((i=1;i<=txs;i++)); do
    out="$(wallet "$n" /wallet/payment/send "$reqs" | jq -r 'if type == "string" then "ok" else "REJECT:" + (.detail // .reason // tojson) end')"
    [[ "$out" == ok ]] && acc=$((acc + 1)) || echo "[mint] tx $i: $out"
    if (( i % 10 == 0 || i == txs )); then end=$((SECONDS + 120)); while [[ $SECONDS -lt $end && "$(mempool_size "$n")" != 0 ]]; do sleep 2; done; fi
  done
  echo "minted $acc/$txs txs, $((acc * outs)) outputs"; }
# txchain <from> <n> [nanoerg]: n payments from <from>'s wallet to its OWN first address, sent in a burst. The
# wallet spends off-chain (unconfirmed) change, so each payment spends the previous one's output and the n
# transactions form a dependency chain in the mempool (the ChainGenerator self-payment pattern,
# src/test/scala/org/ergoplatform/tools/ChainGenerator.scala, driven through the wallet API rather than built by
# hand). Prints one line per attempt: the 64-hex tx id when accepted, or "REJECT:<node text>". The caller counts
# the accepted ids and inspects the mempool (mempool_ids / mempool_size) for how many were admitted unconfirmed
# and whether their listed order kept every parent ahead of its child.
txchain(){
  local n="$1" cnt="$2" amt="${3:-100000000}" to i out
  to="$(address "$n")"; [[ -n "$to" ]] || { echo "no address for $n"; return 1; }
  for ((i=1;i<=cnt;i++)); do
    out="$(wallet "$n" /wallet/payment/send "[{\"address\":\"$to\",\"value\":$amt}]" \
           | jq -r 'if type == "string" then . else "REJECT:" + (.detail // .reason // tojson) end')"
    echo "$out"
    sleep 0.3   # let the node register each unconfirmed tx so the next payment can spend its change
  done
}

# ---- external solver (nodes without an internal miner) ----
# A node whose "mining": true only serves candidates (arkadianet: use_external_miner must be true) is driven by
# this loop: read /mining/candidate, submit one solution, wait, repeat. On the rust-devnet preset the difficulty is
# 1, so the fixed zero-nonce solution below is valid for every candidate (the same solution the node's own
# mixed-devnet driver submits); pk = w = the public test key whose secret scalar is 1. A stale or duplicate
# submission is rejected by the node and logged, not fatal. Log: $RIG_LOG_DIR/solver_<node>.log.
SOLVER_PK="0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798"
declare -A SOLVER_PID
solve_loop(){ local n="$1" c r last=""
  while :; do
    c="$(wallet "$n" /mining/candidate)"
    if jq -e '.msg' <<< "$c" >/dev/null 2>&1 && [[ "$c" != "$last" ]]; then
      r="$(wallet "$n" /mining/solution "{\"pk\":\"$SOLVER_PK\",\"w\":\"$SOLVER_PK\",\"n\":\"0000000000000000\",\"d\":0}")"
      echo "$(date +%T) h=$(full_height "$n") msg=$(jq -r '.msg' <<< "$c" | cut -c1-16) -> ${r:-accepted(empty)}"; last="$c"
    fi
    sleep "${SOLVE_POLL_S:-1}"
  done; }
solve_start(){ local n="$1"
  [[ -n "${SOLVER_PID[$n]:-}" ]] && return 0
  solve_loop "$n" >> "$RIG_LOG_DIR/solver_$n.log" 2>&1 &
  SOLVER_PID[$n]=$!; echo "[solver] started for $n (pid ${SOLVER_PID[$n]}, poll ${SOLVE_POLL_S:-1}s)"; }
solve_stop(){ local n="$1" p="${SOLVER_PID[$1]:-}"
  [[ -n "$p" ]] && { kill "$p" 2>/dev/null; wait "$p" 2>/dev/null; }
  SOLVER_PID[$n]=""; echo "[solver] stopped for $n"; }

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

# ---- mining control ----
# The node has no runtime mining switch (/mining/* serves candidates and solutions only). Two controls exist: the
# per-node "mine_poll" rate at launch, and the relaunch helpers below, which flip ergo.node.mining and restart the
# node. A relaunched node restores its chain from its own data dir.
relaunch(){ # $1=node: stop, wait for a full exit (RocksDB lock and ports released), start, wait_up, then wait for
  # the node to report its previous full height again: REST answers before the node has reloaded its chain, and a
  # height read in that gap is 0 (bounded by PEERYARD_RELOAD_TIMEOUT, default 60 s; a node that stays below, e.g.
  # a damaged one, is reported and the hook goes on)
  local n="$1"; local p="${PID[$n]:-}" h0 end
  h0=$(full_height "$n" 2>/dev/null); [[ "$h0" =~ ^[0-9]+$ ]] || h0=0
  if [[ -n "$p" ]]; then
    kill "$p" 2>/dev/null
    for _ in $(seq 1 40); do kill -0 "$p" 2>/dev/null || break; sleep 0.5; done
    kill -9 "$p" 2>/dev/null || true; wait "$p" 2>/dev/null || true
  fi
  # `kill $PID` hits the `ip netns exec` wrapper, whose java child can outlive it and keep mining and holding the
  # port. Match the node's unique conf path in the java command line and kill that too.
  pkill -9 -f "$SCRATCH/conf_${n}\.(conf|toml)" 2>/dev/null || true
  sleep 2
  launch "$n"; wait_up "$n" || return 1
  end=$((SECONDS + ${PEERYARD_RELOAD_TIMEOUT:-60}))
  while [[ $SECONDS -lt $end ]]; do [[ "$(full_height "$n" 2>/dev/null)" -ge "$h0" ]] 2>/dev/null && return 0; sleep 1; done
  echo "[rig] $n reports full height $(full_height "$n" 2>/dev/null) after the relaunch, below its $h0 before it"; return 0
}
# mining_is <node> <true|false>: a JVM node's /info reports the mining setting it was relaunched with; anything else
# (no answer, the other value) is a harness failure. Other kinds do not report it and are not checked.
mining_is(){ [[ "${KIND[$1]:-jvm}" == jvm ]] || return 0
  local got; got=$(rest "$1" /info | jq -r 'if .isMining == null then empty else (.isMining | tostring) end' 2>/dev/null)   # not `// empty`: false would vanish
  [[ "$got" == "$2" ]] || { harness_fail "$1 relaunched with mining=$2 but /info reports isMining=${got:-nothing}"; return 1; }; }
stop_mining(){  MINING_OVR[$1]=false; echo "[mine] stop_mining($1)"; relaunch "$1" || harness_fail "stop_mining $1: no REST after relaunch"; mining_is "$1" false; }
start_mining(){ MINING_OVR[$1]=true; POLL_OVR[$1]="${2:-500ms}"; echo "[mine] start_mining($1 poll=${POLL_OVR[$1]})"; relaunch "$1" || harness_fail "start_mining $1: no REST after relaunch"; mining_is "$1" true; }
# mine <node> <n> [poll]: advance about n blocks, then stop mining. A larger poll overshoots less.
mine(){
  local n="$1" cnt="$2" poll="${3:-6s}" h0 target h end
  h0=$(full_height "$n"); target=$((h0+cnt))
  echo "[mine] mine($n,$cnt) h0=$h0 target=$target poll=$poll"
  MINING_OVR[$n]=true; POLL_OVR[$n]="$poll"; relaunch "$n" || harness_fail "mine $n: no REST after relaunch"; mining_is "$n" true
  end=$((SECONDS+240))
  while [[ $SECONDS -lt $end ]]; do
    h=$(full_height "$n"); [[ "${h:-0}" -ge "$target" ]] && break; sleep 1
  done
  stop_mining "$n"
  local hf; hf=$(full_height "$n")
  echo "[mine] mine($n,$cnt) reached final=$hf (overshoot=$((hf-target)))"
}
# stop_all: TERM every node, wait for graceful exits (the node flushes its databases on TERM; a KILL right after
# TERM loses the last blocks, seen as a 12-block rollback on restart), then KILL whatever is left.
stop_all(){ local n p end
  for n in "${NODES[@]}"; do [[ -n "${SOLVER_PID[$n]:-}" ]] && kill "${SOLVER_PID[$n]}" 2>/dev/null; done
  for n in "${NODES[@]}"; do [[ -n "${PID[$n]:-}" ]] && kill "${PID[$n]}" 2>/dev/null; done
  end=$((SECONDS + ${RIG_STOP_GRACE_S:-30}))
  while [[ $SECONDS -lt $end ]]; do
    p=0; for n in "${NODES[@]}"; do pgrep -f "$SCRATCH/conf_${n}\.(conf|toml)" >/dev/null 2>&1 && p=1; done
    [[ $p == 0 ]] && break; sleep 1
  done
  for n in "${NODES[@]}"; do pkill -9 -f "$SCRATCH/conf_${n}\.(conf|toml)" 2>/dev/null || true; done
  wait 2>/dev/null; echo "[rig] all nodes stopped$([[ $p == 1 ]] && echo ' (some killed after the grace period)')"; }
trap stop_all EXIT

# A node with "defer": true is not launched at bring-up; the hook calls `launch <n>; wait_up <n>` itself
# (a first launch, not a restart; e.g. after setting CONF_OVR[n]="ergo.chain.genesisId=...").
deferred(){ [[ "$(jq -r --arg n "$1" 'first(.nodes[]|select(.name==$n).defer) // false' "$CFG")" == "true" ]]; }
[[ -n "$REWARD_DELAY" && -z "$GENESIS_DIGEST" ]] && derive_genesis_digest

# The effective configuration: what network this run actually ran, as data, for the record a result should carry.
echo "$$" > "$SCRATCH/rig.pid"
jars_json="$(for n in "${NODES[@]}"; do printf '%s\t%s\t%s\t%s\n' "$n" "$(basename "${NODE_JAR[$n]}")" "$(sha256sum "${NODE_JAR[$n]}" | cut -c1-16)" "${KIND[$n]}"; done \
  | jq -R -s 'split("\n") | map(select(length > 0) | split("\t") | {(.[0]): {kind: .[3], jar: .[1], jar_sha256_16: .[2]}}) | add // {}')"
JAVA_VERSION="$("$JAVA_BIN" -version 2>&1 | head -1)"
echo "[rig] java: $JAVA_VERSION ($JAVA_BIN, opts: $JAVA_OPTS)"
# The host card: what machine the run had, so a number measured here can be read as a fact about this host. affinity
# is the rig's own CPU mask (a run under `taskset` shows it); cpus_online is the host's count. tcp_* are read inside
# a node's namespace (each namespace has its own). scratch_virtual_disk: under WSL2 the scratch filesystem sits on a
# virtual disk file, so its speed is the host's, filtered.
host_card(){ local virt ns="${NS[${NODES[0]}]}"
  if grep -qi microsoft /proc/version 2>/dev/null; then virt=wsl2; else virt="$(systemd-detect-virt 2>/dev/null)"; [[ -z "$virt" || "$virt" == none ]] && virt=""; fi
  jq -n --arg kernel "$(uname -r)" --arg online "$(getconf _NPROCESSORS_ONLN)" --arg aff "$RIG_AFFINITY" \
        --arg mem "$(awk '/^MemTotal:/ {printf "%d", $2/1024}' /proc/meminfo)" \
        --arg model "$(awk -F': ' '/^model name/ {print $2; exit}' /proc/cpuinfo)" --arg virt "$virt" \
        --arg fs "$(stat -fc %T "$SCRATCH" 2>/dev/null)" \
        --arg cc "$(ip netns exec "$ns" cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null)" \
        --arg r2 "$(ip netns exec "$ns" cat /proc/sys/net/ipv4/tcp_retries2 2>/dev/null)" '
    def nn: if . == "" then null else . end;
    { kernel: $kernel, cpus_online: ($online | tonumber), affinity: $aff, mem_mb: ($mem | tonumber),
      cpu_model: ($model | nn), virt: ($virt | nn), scratch_fs: ($fs | nn), scratch_virtual_disk: ($virt == "wsl2"),
      tcp_cc: ($cc | nn), tcp_retries2: (if $r2 == "" then null else ($r2 | tonumber) end) }'; }
jq -n --slurpfile cfg "$CFG" --argjson jars "$jars_json" --arg preset "$CHAIN_PRESET" --arg bi "$BLOCK_INTERVAL" --arg rd "$REWARD_DELAY" \
      --arg gd "$GENESIS_DIGEST" --argjson magic "$MAGIC" --arg poll "$DEFAULT_POLL" --arg dur "${PEERYARD_DURATION:-}" --arg keep "${PEERYARD_KEEP_DATA:-0}" \
      --arg jv "$JAVA_VERSION" --arg jb "$JAVA_BIN" --arg jo "$JAVA_OPTS" --argjson host "$(host_card)" '
  $cfg[0] as $c
  | { effective_schema_version: 1, host: $host,
      chain: { preset: $preset, blockInterval: (if $bi == "" then "jar default" else $bi end),
               minerRewardDelay: (if $rd == "" then "jar default" else ($rd | tonumber) end),
               genesisStateDigestHex: (if $gd == "" then null else $gd end) },
      magic: $magic,
      java: { version: $jv, binary: $jb, opts: $jo },
      nodes: [ $c.nodes[] | { name, mining: (.mining // false), mine_poll: (if .mining // false then (.mine_poll // $poll) else null end),
                              knownPeers: (.knownPeers // []), defer: (.defer // false), conf: (.conf // {}) } + $jars[.name] ],
      links: [ $c.links[] | { a, b,
                              ab: { delay_ms: (.delay_ms_ab // .delay_ms // 0), loss_pct: (.loss_pct_ab // .loss_pct // 0), jitter_ms: (.jitter_ms_ab // .jitter_ms // 0), rate_kbit: (.rate_kbit_ab // .rate_kbit // 0) },
                              ba: { delay_ms: (.delay_ms_ba // .delay_ms // 0), loss_pct: (.loss_pct_ba // .loss_pct // 0), jitter_ms: (.jitter_ms_ba // .jitter_ms // 0), rate_kbit: (.rate_kbit_ba // .rate_kbit // 0) } } ],
      duration_s: (if $dur == "" then null else ($dur | tonumber) end), keep_data: ($keep == "1") }' > "$RIG_LOG_DIR/effective.json"
echo "[rig] effective configuration: $RIG_LOG_DIR/effective.json ($(jq -c '{chain: .chain.preset, nodes: [.nodes[] | .name + ":" + .jar], links: (.links | length)}' "$RIG_LOG_DIR/effective.json"))"
# ---- prefix fixtures ("snapshot starts") ----
# PEERYARD_FIXTURES=<dir>: a hook whose prefix is long (a chain to a snapshot height, matured rewards, minted boxes)
# calls `fixture_save k=v ...` where the prefix ends: the rig stops the running nodes gracefully (stop_all's TERM and
# grace), archives their data dirs and the given values under a key, and relaunches them. A later run with the same
# key restores those data dirs here, before bring-up; the hook asks `fixture_restored` and skips its prefix (the
# saved values are set again as shell variables). The key covers every node's jar (sha256), the topology, the hook
# and the chain settings, so any change to them builds a new fixture. Off when PEERYARD_FIXTURES is unset.
FIXTURE_RESTORED=0
fixture_key(){ { for n in "${NODES[@]}"; do sha256sum "${NODE_JAR[$n]}" | cut -d' ' -f1; done
                 cat "$CFG" "$HOOK"; echo "chain=${PEERYARD_CHAIN:-} bi=${BLOCK_INTERVAL:-} rd=${REWARD_DELAY:-} gd=${GENESIS_DIGEST:-}"
               } | sha256sum | cut -c1-16; }
fixture_path(){ echo "${PEERYARD_FIXTURES%/}/$(basename "$HOOK" .sh)-$(fixture_key)"; }
fixture_restored(){ [[ "$FIXTURE_RESTORED" == 1 ]]; }
fixture_save(){ # fixture_save k=v ...: archive the data dirs of the running nodes and the values, then relaunch them
  [[ -n "${PEERYARD_FIXTURES:-}" ]] || return 0
  fixture_restored && return 0
  local dir; dir="$(fixture_path)"; local tmp="$dir.tmp.$$" running=() n kv
  for n in "${NODES[@]}"; do [[ -n "${PID[$n]:-}" ]] && kill -0 "${PID[$n]}" 2>/dev/null && running+=("$n"); done
  echo "[fixture] saving ${running[*]} -> $dir"
  declare -A h0; for n in "${running[@]}"; do h0[$n]=$(full_height "$n" 2>/dev/null); [[ "${h0[$n]}" =~ ^[0-9]+$ ]] || h0[$n]=0; done
  # stop the nodes gracefully (TERM; the node flushes its databases), poll until they are gone, KILL what is left.
  # Not stop_all: its final `wait` also waits for the rig's background diag sampler, which never ends mid-run.
  for n in "${running[@]}"; do kill "${PID[$n]}" 2>/dev/null; done
  local end=$((SECONDS + ${RIG_STOP_GRACE_S:-30})) left
  while [[ $SECONDS -lt $end ]]; do
    left=0; for n in "${running[@]}"; do pgrep -f "$SCRATCH/conf_${n}\.(conf|toml)" >/dev/null 2>&1 && left=1; done
    [[ $left == 0 ]] && break; sleep 1
  done
  for n in "${running[@]}"; do pkill -9 -f "$SCRATCH/conf_${n}\.(conf|toml)" 2>/dev/null || true; done
  mkdir -p "$tmp"
  for n in "${running[@]}"; do tar -C "$SCRATCH" -czf "$tmp/data_$n.tgz" "data_$n"; done
  : > "$tmp/vars"; for kv in "$@"; do printf '%s\n' "$kv" >> "$tmp/vars"; done
  printf '%s\n' "${running[@]}" > "$tmp/nodes"
  for n in "${running[@]}"; do printf '%s %s\n' "$n" "${h0[$n]}"; done > "$tmp/heights"
  { echo "key=$(fixture_key)"; echo "hook=$(basename "$HOOK")"; date -u +saved=%FT%TZ
    for n in "${NODES[@]}"; do echo "jar_$n=$(sha256sum "${NODE_JAR[$n]}" | cut -d' ' -f1)"; done; } > "$tmp/meta"
  rm -rf "$dir"; mv "$tmp" "$dir"
  for n in "${running[@]}"; do launch "$n"; done
  for n in "${running[@]}"; do wait_up "$n" || echo "[fixture] $n did not come back up after the save"; done
  # REST answers before a node has reloaded its chain (a read in that gap sees height 0 and no blocks): wait for each
  # node's full height to return to its height before the save, as relaunch() does
  local rend=$((SECONDS + ${PEERYARD_RELOAD_TIMEOUT:-60}))
  for n in "${running[@]}"; do
    while [[ $SECONDS -lt $rend ]]; do [[ "$(full_height "$n" 2>/dev/null)" -ge "${h0[$n]}" ]] 2>/dev/null && break; sleep 1; done
  done
  for kv in "$@"; do printf -v "${kv%%=*}" '%s' "${kv#*=}"; done
}
if [[ -n "${PEERYARD_FIXTURES:-}" ]]; then
  fx="$(fixture_path)"
  if [[ -d "$fx" && "${PEERYARD_FIXTURE_MODE:-use}" != rebuild ]]; then
    while IFS= read -r n; do [[ -n "$n" ]] && tar -C "$SCRATCH" -xzf "$fx/data_$n.tgz" && FRESH_DONE[$n]=1; done < "$fx/nodes"
    while IFS= read -r kv; do [[ -n "$kv" ]] && printf -v "${kv%%=*}" '%s' "${kv#*=}"; done < "$fx/vars"
    declare -A FIXTURE_HEIGHT=()
    if [[ -f "$fx/heights" ]]; then while read -r n h; do [[ -n "$n" ]] && FIXTURE_HEIGHT[$n]="$h"; done < "$fx/heights"
    else while IFS= read -r n; do [[ -n "$n" ]] && FIXTURE_HEIGHT[$n]=1; done < "$fx/nodes"; fi   # older fixture: any chain
    FIXTURE_RESTORED=1
    echo "[fixture] restored $(tr '\n' ' ' < "$fx/nodes")from $fx ($(grep ^saved= "$fx/meta"))"
  else
    echo "[fixture] none for this key yet: the hook builds its prefix and saves it ($fx)"
  fi
fi
for n in "${NODES[@]}"; do deferred "$n" || launch "$n"; done
for n in "${NODES[@]}"; do deferred "$n" || wait_up "$n" || { echo "FAIL: node $n never answered on REST within ${PEERYARD_UP_TIMEOUT:-60} s at bring-up (log: $RIG_LOG_DIR/node_$n.log, last lines below); the hook is not run"; grep -v '^\s*at ' "$RIG_LOG_DIR/node_$n.log" | tail -5; exit 2; }; done
# A restored node answers on REST before it has reloaded its chain (a read in that gap sees height 0 and no genesis):
# the hook starts only once every restored node is back at the full height it had when the fixture was saved.
if fixture_restored; then
  rend=$((SECONDS + ${PEERYARD_RELOAD_TIMEOUT:-60}))
  for n in "${!FIXTURE_HEIGHT[@]}"; do
    until [[ "$(full_height "$n" 2>/dev/null)" =~ ^[0-9]+$ && "$(full_height "$n" 2>/dev/null)" -ge "${FIXTURE_HEIGHT[$n]}" ]]; do
      [[ $SECONDS -ge $rend ]] && { echo "FAIL: restored node $n is at full height '$(full_height "$n" 2>/dev/null)', below its saved ${FIXTURE_HEIGHT[$n]}, after ${PEERYARD_RELOAD_TIMEOUT:-60} s; the hook is not run (fixture $fx)"; exit 2; }
      sleep 1
    done
    echo "[fixture] $n reloaded to full height $(full_height "$n") (saved ${FIXTURE_HEIGHT[$n]})"
  done
fi

# bring-up gate (see the header): links between launched nodes, re-dialled once from a JVM end if missing
bringup_links(){ local end=$((SECONDS + ${PEERYARD_BRINGUP_S:-90})) grace=$((SECONDS + ${PEERYARD_BRINGUP_GRACE_S:-30})) redialed=" " i a b from to missing
  while :; do
    missing=0
    for i in "${!LINK_A[@]}"; do a="${LINK_A[$i]}"; b="${LINK_B[$i]}"
      [[ -n "${PID[$a]:-}" && -n "${PID[$b]:-}" ]] || continue   # a deferred node is launched by the hook
      [[ " $(peers_of "$a")" == *" $b "* && " $(peers_of "$b")" == *" $a "* ]] && continue
      missing=1; [[ $SECONDS -lt $grace || "$redialed" == *" $a,$b "* ]] && continue   # the nodes dial first
      from="$a"; to="$b"; [[ "${KIND[$from]}" == jvm ]] || { from="$b"; to="$a"; }
      if [[ "${KIND[$from]}" == jvm ]]; then
        wallet "$from" /peers/connect "\"${IP[$to]}:${P2P[$to]}\"" >/dev/null
        echo "[rig] bring-up: link $a<->$b not connected; re-dialled $to from $from"
      fi
      redialed+="$a,$b "
    done
    [[ $missing == 0 ]] && { echo "[rig] bring-up: every link connected"; return 0; }
    [[ $SECONDS -ge $end ]] && return 1
    sleep 3
  done; }
if [[ "$(jq -r 'if .bringup_links == false then "off" else "on" end' "$CFG")" == on ]]; then
  bringup_links || { echo "FAIL: bring-up: a link was still not connected after ${PEERYARD_BRINGUP_S:-90} s; the hook is not run"; check_topology; exit 2; }
fi

# Named causes (diag/diagnose.py): every node's /info is sampled every PEERYARD_SAMPLE_S (default 3) s while the
# hook runs, into $RIG_LOG_DIR/samples.jsonl; a verdict other than PASS is followed by the classifier's cause
# ("[rig] CAUSE <NAME>: evidence", also cause.json). A hook that knows its own reason sets rig_cause (printed first).
# Process state is read by each node's config path (a token only that node's argv holds), since crashes and revives
# change the rig's pid table after this sampler is forked.
diag_sampler(){ local n st info
  while :; do
    local row="" t; t=$(date +%s%3N)
    for n in "${NODES[@]}"; do
      if pgrep -f "$SCRATCH/conf_${n}\\.(conf|toml)" >/dev/null 2>&1; then st=running; else st=down; fi
      info=""; [[ $st == running ]] && info=$(ip netns exec "${NS[$n]}" curl -s --max-time 2 "http://127.0.0.1:${REST[$n]}/info" 2>/dev/null)
      row+=$(jq -cn --arg n "$n" --arg st "$st" --argjson t "$t" --arg info "$info" '($info | (try fromjson catch null)) as $i
        | {name: $n, t: $t, state: $st, answered: ($i != null),
           headersHeight: $i.headersHeight, fullHeight: $i.fullHeight, bestHeaderId: $i.bestHeaderId,
           bestFullHeaderId: $i.bestFullHeaderId, peers: $i.peersCount, mining: $i.isMining}')","
    done
    echo "{\"t\": $t, \"nodes\": [${row%,}]}" >> "$RIG_LOG_DIR/samples.jsonl"
    sleep "${PEERYARD_SAMPLE_S:-3}"
  done; }
diag_sampler & DIAG_PID=$!
trap 'kill "$DIAG_PID" 2>/dev/null; stop_all' EXIT

echo "[rig] === handing off to hook: $HOOK ==="
export NODES RIG_LOG_DIR
# shellcheck disable=SC1090
source "$HOOK"
kill "$DIAG_PID" 2>/dev/null; wait "$DIAG_PID" 2>/dev/null
if [[ ${#HARNESS_FAIL[@]} -gt 0 ]]; then
  echo "[rig] the harness failed ${#HARNESS_FAIL[@]} time(s); verdict ${rig_verdict:-none} -> INCONCLUSIVE; any PASS line above does not count"
  rig_verdict=INCONCLUSIVE; rig_cause="HARNESS: $(IFS='; '; echo "${HARNESS_FAIL[*]}")"
fi
# A hook reports its conclusion in rig_verdict (PASS, FAIL or INCONCLUSIVE); the rig's exit status follows it
# (0, 1, 3), so a caller can chain on it. A hook that sets nothing exits 0 with "verdict: none".
if [[ "${rig_verdict:-}" == FAIL || "${rig_verdict:-}" == INCONCLUSIVE ]]; then
  [[ -n "${rig_cause:-}" ]] && echo "[rig] CAUSE (hook) ${rig_cause}"
  if python3 "$(dirname "${BASH_SOURCE[0]}")/../diag/diagnose.py" "$RIG_LOG_DIR/samples.jsonl" --json > "$RIG_LOG_DIR/cause.json" 2>/dev/null; then
    echo "[rig] CAUSE $(jq -r '"\(.cause): \(.evidence)"' "$RIG_LOG_DIR/cause.json")"
  else echo "[rig] CAUSE UNKNOWN: the classifier could not read $RIG_LOG_DIR/samples.jsonl"; fi
fi
echo "[rig] === hook done (verdict: ${rig_verdict:-none}) ==="
[[ "${rig_verdict:-}" == FAIL ]] && exit 1
[[ "${rig_verdict:-}" == INCONCLUSIVE ]] && exit 3
exit 0
