#!/usr/bin/env bash
# ergo-sibling-fork.sh: do a node's best full block and best header ever sit on different forks at the same
# height (ergoplatform/ergo issue #525)?
#
#   bash ergo-sibling-fork.sh <ergo-node.jar>
#
# Four real node processes (--devnet, private magic), each in its own network namespace, with one veth pair
# per link. No root is needed: the script runs itself under `unshare -Urmn`. The one exception: if the
# sch_netem kernel module is not loaded and cannot be auto-loaded, run `sudo modprobe sch_netem` once.
#
#   A (miner) ---D_AC--- C (miner)      Miners poll at P (A) and P_C (C); unequal rates let forks resolve. The
#     |  \              /  |            latency between them makes equal-height sibling blocks common. Followers L and S are
#     |   \--D_X-- --D_X/  |            close to one miner and far from the other. Nobody is restarted.
#     L (follower)    S (follower)
#
# For W seconds, /info is polled on all four nodes as fast as they answer. Reported per node:
#   D = samples with fullHeight == headersHeight but bestFullHeaderId != bestHeaderId (full block and header
#       on different forks at the same height); E = distinct such episodes (independent of polling speed);
#   G = the longest continuous stretch with fullHeight < headersHeight (the full chain lagging the header chain).
# At the end: whether all four nodes agree on the header id at min(fullHeight) - 5.
#
# Requires: Linux with unprivileged user namespaces, util-linux (unshare, mount), iproute2 (ip, tc) with
#           sch_netem, jq, curl, unzip, awk, bash 4+, and a Java runtime the jar supports on PATH.
# Env: D_AC (ms, default 500), D_X (ms, default D_AC/2), P (miner A polling, default 4s), P_C (miner C, default 5s),
#      W (seconds, 150), HDR_TRIES (5: reads of an empty header-id reply before the run is INCONCLUSIVE),
#      WORKDIR (default: mktemp -d). Use a fresh WORKDIR for each run.
# Runtime: about W + 2 minutes. RAM: 4 JVMs at -Xmx512m.
set -uo pipefail
JAVA_VERSION="$(${PEERYARD_JAVA:-java} -version 2>&1 | head -1)"; echo "[java] $JAVA_VERSION (${PEERYARD_JAVA:-java} ${PEERYARD_JAVA_OPTS:--Xmx512m})"

if [[ "${FC_INNER:-0}" != 1 ]]; then
  JAR="$(readlink -f "${1:?usage: $0 <ergo-node.jar>}")"
  [[ -f "$JAR" ]] || { echo "no jar: $JAR" >&2; exit 2; }
  for c in unshare ip tc jq curl unzip awk; do command -v "$c" >/dev/null || { echo "missing: $c" >&2; exit 2; }; done
  command -v "${PEERYARD_JAVA:-java}" >/dev/null || { echo "missing: ${PEERYARD_JAVA:-java} (PEERYARD_JAVA)" >&2; exit 2; }
  WORKDIR="${WORKDIR:-$(mktemp -d)}"; mkdir -p "$WORKDIR"; WORKDIR="$(readlink -f "$WORKDIR")"
  [[ -e "$WORKDIR/node_A.log" ]] && { echo "WORKDIR $WORKDIR was already used; pass a fresh one" >&2; exit 2; }
  unshare -Urmn true 2>/dev/null || { echo "unprivileged user namespaces are unavailable here (on Ubuntu 23.10+:" \
    "sudo sysctl kernel.apparmor_restrict_unprivileged_userns=0, or use a VM)" >&2; exit 2; }
  export FC_INNER=1 JAR WORKDIR
  exec unshare -Urmn bash "$(readlink -f "${BASH_SOURCE[0]}")"
fi

# ---------------- inside the namespaces ----------------
D_AC=${D_AC:-500}; D_X=${D_X:-$((D_AC/2))}; P=${P:-4s}; P_C=${P_C:-5s}; W=${W:-150}
MAGIC='[112,101,101,114]'   # "peer": private, so these nodes never talk to a public network
# Ergo's own public test mnemonic (src/main/resources/nodeTestnet/application.conf); gives miners a reward address.
MNEMONIC="ozone drill grab fiber curtain grace pudding thank cruise elder eight picnic"
API_HASH=324dcf027dd4a30a932c441f365a25e86b173defa4b8e58948253471b81b72cf
echo "[sf] jar=$JAR sha256=$(sha256sum "$JAR" | cut -c1-16) D_AC=${D_AC}ms D_X=${D_X}ms P=$P P_C=$P_C W=${W}s workdir=$WORKDIR"
echo "[sf] java: $("${PEERYARD_JAVA:-java}" -version 2>&1 | head -1)"

mount --make-rprivate / 2>/dev/null || true
mount -t tmpfs tmpfs /run || { echo "FAIL: cannot mount tmpfs on /run in the user namespace"; exit 10; }
mkdir -p /run/netns
# The node resolves some fallback configs relative to its CWD; give it the jar's own copies.
RT="$WORKDIR/rt"; mkdir -p "$RT/src/main/resources"
unzip -o -q "$JAR" application.conf devnet.conf mainnet.conf testnet.conf -d "$RT/src/main/resources"

NODES=(A C L S)
declare -A LIP PRIMARY PID
for n in "${NODES[@]}"; do ip netns add "ns_$n"; ip -n "ns_$n" link set lo up; done
LINKS=("A C" "A L" "A S" "C L" "C S")          # link i -> subnet 10.9.(20+i).0/30; first node .1, second .2
for i in "${!LINKS[@]}"; do
  read -r a b <<< "${LINKS[$i]}"; s="10.9.$((20+i))"
  ip link add "ve_${a}_${b}" type veth peer name "ve_${b}_${a}"
  ip link set "ve_${a}_${b}" netns "ns_$a"; ip link set "ve_${b}_${a}" netns "ns_$b"
  ip -n "ns_$a" addr add "$s.1/30" dev "ve_${a}_${b}"; ip -n "ns_$b" addr add "$s.2/30" dev "ve_${b}_${a}"
  ip -n "ns_$a" link set "ve_${a}_${b}" up; ip -n "ns_$b" link set "ve_${b}_${a}" up
  LIP["$a,$b"]="$s.1"; LIP["$b,$a"]="$s.2"
  [[ -z "${PRIMARY[$a]:-}" ]] && PRIMARY[$a]="$s.1"; [[ -z "${PRIMARY[$b]:-}" ]] && PRIMARY[$b]="$s.2"
done
netem(){ ip netns exec "ns_$1" tc qdisc replace dev "ve_${1}_${2}" root netem $3; }   # $1->$2 direction
delay(){ netem "$1" "$2" "delay ${3}ms" && netem "$2" "$1" "delay ${3}ms"; }
{ delay A C "$D_AC" && delay A S "$D_X" && delay C L "$D_X"; } || { echo "FAIL: tc netem unavailable (try: sudo modprobe sch_netem)"; exit 10; }

declare -A MINING=([A]=true [C]=true [L]=false [S]=false) POLL=([A]=$P [C]=$P_C)
declare -A PEERS=([A]="C L S" [C]="A L S" [L]="A C" [S]="A C")
declare -A EXTRA
conf(){ local n=$1; local f="$WORKDIR/conf_$n.conf" kp="" p
  for p in ${PEERS[$n]}; do kp+="\"${LIP[$p,$n]}:9021\","; done
  { echo "ergo.directory=\"$WORKDIR/data_$n\""
    echo "ergo.node.mining=${MINING[$n]}"; echo "ergo.node.offlineGeneration=${MINING[$n]}"
    echo "ergo.node.useExternalMiner=false"
    [[ ${MINING[$n]} == true ]] && echo "ergo.node.internalMinerPollingInterval=${POLL[$n]}"
    echo "ergo.wallet.testMnemonic=\"$MNEMONIC\""; echo "ergo.wallet.testKeysQty=5"
    echo "scorex.network.bindAddress=\"0.0.0.0:9021\""
    echo "scorex.network.declaredAddress=\"${PRIMARY[$n]}:9021\""
    echo "scorex.network.knownPeers=[${kp%,}]"
    echo "scorex.network.allowLocal=true"; echo "scorex.network.nodeName=\"$n\""
    echo "scorex.network.magicBytes=$MAGIC"
    echo "scorex.restApi.bindAddress=\"127.0.0.1:9052\""; echo "scorex.restApi.apiKeyHash=\"$API_HASH\""
    # settings from Ergo's src/it/resources/devnetTemplate.conf, so a sole-peer follower fully syncs
    echo "ergo.node.stateType=utxo"; echo "ergo.node.verifyTransactions=true"; echo "ergo.node.blocksToKeep=-1"
    echo "ergo.node.mempoolCapacity=10000"
    echo "ergo.chain.powScheme.powType=autolykos"; echo "ergo.chain.powScheme.k=32"; echo "ergo.chain.powScheme.n=26"
    [[ -n "${EXTRA[$n]:-}" ]] && echo "${EXTRA[$n]}"
  } > "$f"; echo "$f"; }
# Each node gets its own java.io.tmpdir so that four nodes starting at once on one host do not interfere at startup.
launch(){ local n=$1 c; c=$(conf "$n"); mkdir -p "$WORKDIR/data_$n" "$WORKDIR/tmp_$n"
  ip netns exec "ns_$n" bash -c "cd '$RT' && exec '${PEERYARD_JAVA:-java}' ${PEERYARD_JAVA_OPTS:--Xmx512m} -Djava.io.tmpdir='$WORKDIR/tmp_$n' -jar '$JAR' --devnet -c '$c'" >> "$WORKDIR/node_$n.log" 2>&1 &
  PID[$n]=$!; }
rest(){ ip netns exec "ns_$1" curl -s --max-time 4 "http://127.0.0.1:9052$2"; }
f(){ local v; v=$(rest "$1" /info | jq -r ".$2 // \"null\"" 2>/dev/null); echo "${v:-null}"; }   # "null" if unreachable
header_at(){ rest "$1" "/blocks/at/$2" | jq -r '.[0] // empty'; }
# hdr <node> <height>: header_at, retried: an empty reply (REST busy or timed out) means "not read", never an id.
# Prints the id and returns 0, or returns 1 after HDR_TRIES empty replies, 1 s apart.
hdr(){ local i v; for ((i=1; i<=${HDR_TRIES:-5}; i++)); do v=$(header_at "$1" "$2"); [[ -n "$v" ]] && { echo "$v"; return 0; }; sleep 1; done; return 1; }
wait_up(){ local end=$((SECONDS+90)); while [[ $SECONDS -lt $end ]]; do rest "$1" /info | jq -e .appVersion >/dev/null 2>&1 && return 0; sleep 2; done; return 1; }
POLLER=""
cleanup(){ [[ -n "$POLLER" ]] && kill "$POLLER" 2>/dev/null
           for n in "${NODES[@]}"; do [[ -n "${PID[$n]:-}" ]] && kill "${PID[$n]}" 2>/dev/null; done
           pkill -f "$WORKDIR/conf_" 2>/dev/null; wait 2>/dev/null; }
trap cleanup EXIT
# die <CAUSE> <message>: the cause code (a fixed vocabulary, carried into verdict.json by run.sh) and the reason
die(){ local c="$1"; shift; echo "CAUSE $c"; echo "[sf] INCONCLUSIVE: $*"; exit 3; }

for n in A L S; do launch $n; done
for n in A L S; do wait_up $n || die SETUP_NODE_API "$n did not start"; done
end=$((SECONDS+120)); until [[ -n "$(header_at A 3)" ]] || [[ $SECONDS -ge $end ]]; do sleep 2; done
G=$(header_at A 1); [[ "$G" =~ ^[0-9a-f]{64}$ && -n "$(header_at A 3)" ]] || die SETUP_MINING "A did not mine 3 blocks"
EXTRA[C]="ergo.chain.genesisId=\"$G\""; launch C; wait_up C || die SETUP_NODE_API "C did not start"
end=$((SECONDS+120)); until [[ "$(header_at C 1)" == "$G" ]] || [[ $SECONDS -ge $end ]]; do sleep 2; done
[[ "$(header_at C 1)" == "$G" ]] || die SETUP_GENESIS "C did not sync A's genesis"
VA=$(f A appVersion); VC=$(f C appVersion); VL=$(f L appVersion); VS=$(f S appVersion)   # diffrun: identity is taken at startup
echo "[sf] versions: A=$VA C=$VC L=$VL S=$VS; genesis=${G:0:16}"

# observe: one line per node per round: epoch_ms node fullHeight headersHeight bestFullHeaderId bestHeaderId
S0=$(date +%s%3N)
( while :; do for n in "${NODES[@]}"; do
    rest "$n" /info | jq -r --arg n "$n" --arg t "$(date +%s%3N)" \
      '"\($t) \($n) \(.fullHeight // "null") \(.headersHeight // "null") \(.bestFullHeaderId // "null") \(.bestHeaderId // "null")"' 2>/dev/null
  done; done ) > "$WORKDIR/samples.txt" &
POLLER=$!
sleep "$W"
kill "$POLLER" 2>/dev/null; wait "$POLLER" 2>/dev/null; POLLER=""

# agreement at min(fullHeight) - 5
minf=""; for n in "${NODES[@]}"; do h=$(f $n fullHeight); [[ "$h" =~ ^[0-9]+$ ]] || die SETUP_NODE_API "$n not answering at the end"
  [[ -z "$minf" || $h -lt $minf ]] && minf=$h; done
ah=$((minf-5)); [[ $ah -ge 1 ]] || die SETUP_SYNC "min(fullHeight)=$minf is too low for the agreement check at min-5"
ids=""; for n in "${NODES[@]}"; do id=$(hdr "$n" "$ah") || die SETUP_NODE_API "$n's header id at $ah could not be read"; ids+="$id "; done
agree=DIFF; [[ $(echo $ids | tr ' ' '\n' | sort -u | grep -c .) == 1 ]] && agree=SAME
maxh=$(awk '$3 ~ /^[0-9]+$/ && $3>m {m=$3} END {print m+0}' "$WORKDIR/samples.txt")

echo "[sf] samples=$(wc -l < "$WORKDIR/samples.txt") over ${W}s; max fullHeight=$maxh; agreement at h=$ah: $agree"
awk -v s0="$S0" '
  $3 ~ /^[0-9]+$/ && $4 ~ /^[0-9]+$/ {
    n=$2; seen[n]++
    if ($3 == $4 && $5 != $6) { D[n]++; k=n SUBSEP $5 SUBSEP $6; if (!(k in ep)) { ep[k]=1; E[n]++ } }
    if ($3 < $4) { if (!(n in st)) st[n]=$1; len=$1-st[n]; if (len>G[n]) G[n]=len } else delete st[n]
  }
  END { for (n in seen) printf "[sf] node %s: samples=%d D=%d E=%d G=%.1fs\n", n, seen[n], D[n]+0, E[n]+0, (G[n]+0)/1000 }' "$WORKDIR/samples.txt" | sort
Dtot=$(awk '$3 ~ /^[0-9]+$/ && $3==$4 && $5!=$6 {d++} END {print d+0}' "$WORKDIR/samples.txt")
Etot=$(awk '$3 ~ /^[0-9]+$/ && $3==$4 && $5!=$6 {k=$2 SUBSEP $5 SUBSEP $6; if (!(k in e)) {e[k]=1; c++}} END {print c+0}' "$WORKDIR/samples.txt")
# D_confirmed: a mismatch that a node reported in two CONSECUTIVE samples (same node, height, full id, header id):
# one sample can be body-download lag, two in a row is the sustained state the regression spec also requires
Dconf=$(awk '$3 ~ /^[0-9]+$/ { n=$2; k = ($3==$4 && $5!=$6) ? $3 SUBSEP $5 SUBSEP $6 : ""; if (k != "" && k == prev[n]) c++; prev[n]=k } END {print c+0}' "$WORKDIR/samples.txt")
[[ $maxh -ge 128 ]] && echo "[sf] NOTE: heights reached $maxh (>=128: the devnet's version-2 activation height, a one-off difficulty reset). The run is still reported; constrain max_height in the manifest if that matters"
# a verdict needs something to observe: samples whose two ids were both read at equal heights (null ids compare equal,
# which would count as "aligned"), and at least one sibling fork (a height where A knows two blocks)
nonnull=$(awk '$3 ~ /^[0-9]+$/ && $3==$4 && $5 ~ /^[0-9a-f]{64}$/ && $6 ~ /^[0-9a-f]{64}$/ {c++} END {print c+0}' "$WORKDIR/samples.txt")
sibs=0; for ((h = 1; h <= maxh; h++)); do k=$(rest A "/blocks/at/$h" | jq -r 'length' 2>/dev/null); [[ "${k:-0}" -gt 1 ]] && sibs=$((sibs + 1)); done
echo "[sf] samples with both ids read at equal heights: $nonnull; heights with sibling blocks on A: $sibs"
[[ $nonnull -gt 0 ]] || die SETUP_NO_SAMPLES "no sample read both ids at equal heights"
[[ $sibs -gt 0 ]] || die SETUP_NO_SIBLINGS "no sibling fork formed, so the run cannot show whether full block and header stay aligned"
echo "RESULT D_total=$Dtot D_confirmed=$Dconf E_total=$Etot agreement=$agree max_height=$maxh"
# diffrun: nodes whose REST no longer answers after the measurement (recorded, does not void the run)
UNR=""; for n in A C L S; do [[ "$(f $n appVersion)" == null ]] && UNR+="$n "; done
[[ -n "$UNR" ]] && echo "[sf] unresponsive after the measurement: $UNR"
# diffrun: the one machine-readable result line (scenario contract, diffrun/README.md)
echo "RESULT_JSON $(jq -cn --arg A "$VA" --arg C "$VC" --arg L "$VL" --arg S "$VS" --argjson u "$(wc -w <<< "$UNR")" \
  --argjson d "$Dtot" --argjson dc "$Dconf" --argjson e "$Etot" --argjson m "$maxh" --arg ag "$agree" --arg jv "$JAVA_VERSION" \
  '{schema_version:1,scenario:"sibling-fork",versions:{A:$A,C:$C,L:$L,S:$S},runtime:{java:$jv},metrics:{D_total:$d,D_confirmed:$dc,E_total:$e,agreement:($ag=="SAME"),max_height:$m,unresponsive_after:$u}}')"
echo "[sf] samples: $WORKDIR/samples.txt  node logs: $WORKDIR/node_{A,C,L,S}.log"
