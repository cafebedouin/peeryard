#!/usr/bin/env bash
# ergo-fork-convergence.sh: does a follower on a lighter, static fork adopt a heavier fork that its
# only peer holds?
#
#   ./ergo-fork-convergence.sh <ergo-node.jar> [main|reverse]
#
# Four real node processes (--devnet, private magic), each in its own network namespace, with one
# veth pair per link. No root is needed: the script runs itself under `unshare -Urmn` (an
# unprivileged user, mount and net namespace). The one exception: if the sch_netem kernel module is not
# loaded and cannot be auto-loaded, run `sudo modprobe sch_netem` once.
#
#   A (miner, chain X) --- L (follower)          A mines a prefix alone; C starts later with its
#   |                      |                     genesis pinned to A's, syncs the prefix, and the
#   C (miner, chain Y) --- S (follower)          A-C link is then cut. Each miner extends its own fork.
#                                                The L-S link starts fully lossy.
#
# main:    Y is the heavier fork. L is cut from A once it has synced X; S is cut from C once it is
#          ahead by DELTA. Both held chains are then static, and no node is restarted. L-S is opened
#          and L's header id at the fork height is polled for up to TMAX seconds.
#          Expected on a converging node: L switches to Y.
# reverse: X is the heavier fork. L must NOT switch; S should switch to X.
#
# The witness is the header id at the fork height, not a height.
#
# Requires: Linux with unprivileged user namespaces, util-linux (unshare, mount), iproute2 (ip, tc) with
#           sch_netem, jq, curl, unzip, bash 4+, and a Java runtime the jar supports on PATH (the
#           published runs used OpenJDK 21).
# Env: PREFIX_MIN (default 14), LMIN (17: minimum height L is held at; 32 gives a ~15-block fork on L),
#      TMAX (300), DELTA (8), HDR_TRIES (5: reads of an empty header-id reply before the run is INCONCLUSIVE),
#      WORKDIR (default: mktemp -d).
# Runtime: about 3 minutes when L switches, about 7 otherwise. RAM: 4 JVMs at -Xmx512m; peak measured ~1.4 GB.
# Use a fresh WORKDIR for each run. If the script is killed hard, `pkill -f <workdir>/conf_` stops the nodes.
set -uo pipefail
JAVA_VERSION="$(${PEERYARD_JAVA:-java} -version 2>&1 | head -1)"; echo "[java] $JAVA_VERSION (${PEERYARD_JAVA:-java} ${PEERYARD_JAVA_OPTS:--Xmx512m})"

if [[ "${FC_INNER:-0}" != 1 ]]; then
  JAR="$(readlink -f "${1:?usage: $0 <ergo-node.jar> [main|reverse]}")"; MODE="${2:-${FC_MODE:-main}}"   # argv[2], else FC_MODE (a manifest env), else main
  [[ -f "$JAR" ]] || { echo "no jar: $JAR" >&2; exit 2; }
  [[ "$MODE" == main || "$MODE" == reverse ]] || { echo "mode must be main or reverse" >&2; exit 2; }
  for c in unshare ip tc jq curl unzip; do command -v "$c" >/dev/null || { echo "missing: $c" >&2; exit 2; }; done
  command -v "${PEERYARD_JAVA:-java}" >/dev/null || { echo "missing: ${PEERYARD_JAVA:-java} (PEERYARD_JAVA)" >&2; exit 2; }
  WORKDIR="${WORKDIR:-$(mktemp -d)}"; mkdir -p "$WORKDIR"; WORKDIR="$(readlink -f "$WORKDIR")"
  [[ -e "$WORKDIR/node_A.log" ]] && { echo "WORKDIR $WORKDIR was already used; pass a fresh one" >&2; exit 2; }
  unshare -Urmn true 2>/dev/null || { echo "unprivileged user namespaces are unavailable here (on Ubuntu 23.10+:" \
    "sudo sysctl kernel.apparmor_restrict_unprivileged_userns=0, or use a VM)" >&2; exit 2; }
  export FC_INNER=1 JAR MODE WORKDIR
  exec unshare -Urmn bash "$(readlink -f "${BASH_SOURCE[0]}")"
fi

# ---------------- inside the namespaces ----------------
PREFIX_MIN=${PREFIX_MIN:-14}; LMIN=${LMIN:-17}; TMAX=${TMAX:-300}; DELTA=${DELTA:-8}; HOLD=60
MAGIC='[112,101,101,114]'   # "peer": private, so these nodes never talk to a public network
# Ergo's own public test mnemonic (src/main/resources/nodeTestnet/application.conf); gives miners a reward address.
MNEMONIC="ozone drill grab fiber curtain grace pudding thank cruise elder eight picnic"
API_KEY=hello; API_HASH=324dcf027dd4a30a932c441f365a25e86b173defa4b8e58948253471b81b72cf
echo "[fc] jar=$JAR sha256=$(sha256sum "$JAR" | cut -c1-16) mode=$MODE workdir=$WORKDIR"
echo "[fc] java: $("${PEERYARD_JAVA:-java}" -version 2>&1 | head -1)"

mount --make-rprivate / 2>/dev/null || true
mount -t tmpfs tmpfs /run || { echo "FAIL: cannot mount tmpfs on /run in the user namespace"; exit 10; }
mkdir -p /run/netns
# The node resolves some fallback configs relative to its CWD; give it the jar's own copies.
RT="$WORKDIR/rt"; mkdir -p "$RT/src/main/resources"
unzip -o -q "$JAR" application.conf devnet.conf mainnet.conf testnet.conf -d "$RT/src/main/resources"

NODES=(A C L S)
declare -A LIP PRIMARY PID
for n in "${NODES[@]}"; do ip netns add "ns_$n"; ip -n "ns_$n" link set lo up; done
LINKS=("A L" "A C" "C S" "L S")              # link i -> subnet 10.9.(20+i).0/30; first node .1, second .2
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
{ netem L S "loss 100%" && netem S L "loss 100%"; } || { echo "FAIL: tc netem unavailable (try: sudo modprobe sch_netem)"; exit 10; }

if [[ "$MODE" == main ]]; then POLL_A=3s; POLL_C=1s; else POLL_A=1s; POLL_C=3s; fi
declare -A MINING=([A]=true [C]=true [L]=false [S]=false) POLL=([A]=$POLL_A [C]=$POLL_C)
declare -A PEERS=([A]="" [C]="A" [L]="A S" [S]="C L")
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
# find_fork <max height>: the first height at which L and S hold different header ids, in HF. Both ids must be read:
# a height whose id stays unreadable voids the run (INCONCLUSIVE), and so does a fork height at or below the prefix
# both miners shared, which no real fork can have.
find_fork(){ local h hl hs; HF=""
  for ((h=1; h<=$1; h++)); do
    hl=$(hdr L "$h") || die SETUP_NODE_API "L's header id at height $h could not be read"
    hs=$(hdr S "$h") || die SETUP_NODE_API "S's header id at height $h could not be read"
    [[ "$hl" != "$hs" ]] && { HF=$h; break; }
  done
  [[ -n "$HF" ]] || die SETUP_FORK_STAGING "no fork height found"
  [[ "$HF" -gt "$PREFIX_MIN" ]] || die SETUP_PREFIX_RACE "fork height $HF is not above the prefix both miners shared ($PREFIX_MIN)"; }
wait_up(){ local end=$((SECONDS+90)); while [[ $SECONDS -lt $end ]]; do rest "$1" /info | jq -e .appVersion >/dev/null 2>&1 && return 0; sleep 2; done; return 1; }
cleanup(){ for n in "${NODES[@]}"; do [[ -n "${PID[$n]:-}" ]] && kill "${PID[$n]}" 2>/dev/null; done
           pkill -f "$WORKDIR/conf_" 2>/dev/null; wait 2>/dev/null; }
trap cleanup EXIT
cut_(){  netem "$1" "$2" "loss 100%" && netem "$2" "$1" "loss 100%" || die SETUP_NETEM "netem failed"; echo "[fc] cut $1<->$2"; }
open_(){ netem "$1" "$2" "delay 0ms" && netem "$2" "$1" "delay 0ms" || die SETUP_NETEM "netem failed"; echo "[fc] open $1<->$2"; }
snap(){ for n in "${NODES[@]}"; do printf '%s[full=%s hdr=%s score=%s] ' "$n" "$(f $n fullHeight)" "$(f $n headersHeight)" "$(f $n headersScore)"; done; echo; }
synced_to(){ local fh hh; fh=$(f "$1" fullHeight); hh=$(f "$1" headersHeight)   # holder full==hdr and on its miner's chain
  [[ "$fh" != null && "$fh" == "$hh" ]] || return 1; local id; id=$(f "$1" bestFullHeaderId)
  [[ "$id" != null && "$id" == "$(header_at "$2" "$fh")" ]]; }
dial(){ ip netns exec "ns_$1" curl -s --max-time 4 -X POST -H "api_key: $API_KEY" -H "Content-Type: application/json" \
          --data "\"$2:9021\"" http://127.0.0.1:9052/peers/connect >/dev/null; }
conn_to(){ rest "$1" /peers/connected | jq -r --arg p "$2" '[.[]?|select(.name==$p)]|length' 2>/dev/null; }
# die <CAUSE> <message>: the cause code (a fixed vocabulary, carried into verdict.json by run.sh) and the reason
die(){ local c="$1"; shift; echo "CAUSE $c"; echo "[fc] INCONCLUSIVE: $*"; snap; exit 3; }

for n in A L S; do launch $n; done
for n in A L S; do wait_up $n || die SETUP_NODE_API "$n did not start"; done
VA=$(f A appVersion); VL=$(f L appVersion); VS=$(f S appVersion)   # diffrun: identity is taken at startup
echo "[fc] versions: A=$VA L=$VL S=$VS"

# 1. prefix: A mines alone; C starts with genesisId pinned to A's genesis and syncs A's prefix
end=$((SECONDS+180)); until [[ "$(f A fullHeight)" != null && "$(f A fullHeight)" -ge $PREFIX_MIN ]] || [[ $SECONDS -ge $end ]]; do sleep 2; done
[[ -n "$(header_at A $PREFIX_MIN)" ]] || die SETUP_SYNC "A did not reach height $PREFIX_MIN"
G=$(header_at A 1); [[ "$G" =~ ^[0-9a-f]{64}$ ]] || die SETUP_MINING "A mined no genesis"
# C syncs the prefix with its mining off: a miner that catches up can mine a competing block at or below
# PREFIX_MIN before the partition, and the miners then share less prefix than the scenario needs (the run is
# voided). C starts mining only after the A-C cut, on the prefix it already shares with A.
MINING[C]=false
EXTRA[C]="ergo.chain.genesisId=\"$G\""; launch C; wait_up C || die SETUP_NODE_API "C did not start"
VC=$(f C appVersion); echo "[fc] C version=$VC; A genesis=${G:0:16}"
end=$((SECONDS+150)); ok=no
while [[ $SECONDS -lt $end ]]; do
  pa=$(header_at A $PREFIX_MIN)
  # C must hold the prefix as FULL blocks: a miner mines on its best full block, so a C whose headers reached
  # PREFIX_MIN while its blocks lagged (a loaded host) would fork below the prefix once cut off (SETUP_PREFIX_RACE)
  cf=$(f C fullHeight)
  [[ "$(header_at C 1)" == "$G" && "$cf" != null && "$cf" -ge $PREFIX_MIN && -n "$pa" && "$(header_at C $PREFIX_MIN)" == "$pa" ]] && { ok=yes; break; }; sleep 1
done
[[ $ok == yes ]] || die SETUP_SYNC "C did not sync A's prefix as full blocks"
# 2. partition the miners
cut_ A C; P0=$(f A fullHeight); C0=$(f C fullHeight); echo "[fc] partitioned at A.full=$P0 C.full=$C0"
kill "${PID[C]}" 2>/dev/null; wait "${PID[C]}" 2>/dev/null
MINING[C]=true; launch C; wait_up C || die SETUP_NODE_API "C did not restart as a miner"
# REST answers before the node has reloaded its chain (fullHeight reads null in that gap): wait for the reload
end=$((SECONDS+90)); until [[ "$(f C fullHeight)" =~ ^[0-9]+$ && "$(f C fullHeight)" -ge $C0 ]] || [[ $SECONDS -ge $end ]]; do sleep 1; done
[[ "$(f C fullHeight)" =~ ^[0-9]+$ && "$(f C fullHeight)" -ge $C0 ]] || die SETUP_SYNC "C did not reload its chain after the restart (full=$(f C fullHeight), before $C0)"
echo "[fc] C restarted as a miner at C.full=$(f C fullHeight)"
# 3-4. freeze the lighter holder, then the heavier holder once it leads by DELTA
if [[ "$MODE" == main ]]; then LH=L; LM=A; HH=S; HM=C; else LH=S; LM=C; HH=L; HM=A; fi
LMIN_EFF=$LMIN; [[ "$MODE" == reverse ]] && LMIN_EFF=0
end=$((SECONDS+180)); ok=no
while [[ $SECONDS -lt $end ]]; do lf=$(f $LH fullHeight)
  [[ "$lf" != null && "$lf" -ge $((P0+2)) && "$lf" -ge $LMIN_EFF ]] && synced_to $LH $LM && { ok=yes; break; }; sleep 1; done
[[ $ok == yes ]] || die SETUP_SYNC "lighter holder $LH did not sync"
cut_ $LH $LM; sleep 3; LIGHT=$(f $LH fullHeight); echo "[fc] $LH frozen at $LIGHT"
end=$((SECONDS+240)); ok=no
while [[ $SECONDS -lt $end ]]; do hf=$(f $HH fullHeight)
  [[ "$hf" != null && "$hf" -ge $((LIGHT+DELTA)) ]] && synced_to $HH $HM && { ok=yes; break; }; sleep 1; done
[[ $ok == yes ]] || die SETUP_FORK_STAGING "heavier holder $HH did not reach +$DELTA"
cut_ $HH $HM; sleep 5
# 5. preconditions: static, L fully synced, margin, common genesis, fork height, divergent tips
s1="$(f L bestHeaderId) $(f S bestHeaderId)"; sleep 20; s2="$(f L bestHeaderId) $(f S bestHeaderId)"
LF=$(f L fullHeight); LHH=$(f L headersHeight); SF=$(f S fullHeight); LS=$(f L headersScore); SS=$(f S headersScore)
snap
for v in LF SF LS SS; do [[ "${!v}" =~ ^[0-9]+$ ]] || die SETUP_NODE_API "a follower's REST is not answering ($v=${!v})"; done
[[ "$s1" == "$s2" ]] || die SETUP_FORK_STAGING "held chains not static"
[[ "$LF" == "$LHH" ]] || die SETUP_SYNC "L not fully synced (full=$LF hdr=$LHH)"
if [[ "$MODE" == main ]]; then M=$((SS-LS)); else M=$((LS-SS)); fi
[[ $M -ge $DELTA ]] || die SETUP_FORK_STAGING "score margin $M < $DELTA"
gl=$(hdr L 1) && gs=$(hdr S 1) || die SETUP_GENESIS "a genesis header id could not be read"
[[ "$gl" == "$gs" ]] || die SETUP_GENESIS "L and S have different genesis"
find_fork "$LF"
X=$(hdr L $HF) && Y=$(hdr S $HF) || die SETUP_NODE_API "a header id at the fork height could not be read"
low=$(( LF<SF ? LF : SF ))
tl=$(hdr L $low) && ts=$(hdr S $low) || die SETUP_NODE_API "observer control: a tip header id could not be read"
[[ "$tl" != "$ts" ]] || die SETUP_FORK_STAGING "observer control: tips not divergent"
echo "[fc] fork height=$HF L=$LF (score $LS) S=$SF (score $SS) margin=$M"
echo "[fc] X@fork=$X"; echo "[fc] Y@fork=$Y"
# "Extension is empty while comparison is younger" is the node's own sync-negotiation warning (public: it is the
# title of upstream issue ergoplatform/ergo#2464). Counted per follower as warn_S / warn_L because it separates
# switch from no-switch runs.
W0=$(grep -c "Extension is empty while comparison is younger" "$WORKDIR/node_S.log")
W0L=$(grep -c "Extension is empty while comparison is younger" "$WORKDIR/node_L.log")
# 6. open L-S and observe
open_ L S; dial L "${LIP[S,L]}"; dial S "${LIP[L,S]}"; last=$SECONDS; t0=$SECONDS; tL=""; tS=""; everc=0
while [[ $((SECONDS-t0)) -lt $TMAX ]]; do
  lh=$(header_at L $HF); sh=$(header_at S $HF); c=$(conn_to L S); [[ "${c:-0}" =~ ^[1-9] ]] && everc=1
  [[ "${c:-0}" == 0 && $((SECONDS-last)) -ge 20 ]] && { dial L "${LIP[S,L]}"; dial S "${LIP[L,S]}"; last=$SECONDS; }
  stL="?"; [[ "$lh" == "$X" ]] && stL=X; [[ "$lh" == "$Y" ]] && stL=Y
  stS="?"; [[ "$sh" == "$X" ]] && stS=X; [[ "$sh" == "$Y" ]] && stS=Y
  echo "  t+$((SECONDS-t0))s L@fork=$stL S@fork=$stS L.full=$(f L fullHeight) S.full=$(f S fullHeight) connected=${c:-0}"
  same=no; bl=$(f L bestFullHeaderId); [[ "$bl" != null && "$bl" == "$(f S bestFullHeaderId)" ]] && same=yes
  [[ $stL == Y && -z "$tL" && $same == yes ]] && tL=$((SECONDS-t0))
  [[ $stS == X && -z "$tS" && $same == yes ]] && tS=$((SECONDS-t0))
  [[ "$MODE" == main && -n "$tL" ]] && break
  sleep 5
done
# a switch counts only if it still holds HOLD seconds later: L (or S) still has the other fork's id at the fork
# height and both followers are on one tip. An unreadable re-check voids the run rather than keeping the switch.
revL=""; revS=""
if [[ -n "$tL$tS" ]]; then
  sleep $HOLD
  lh=$(hdr L $HF) && sh=$(hdr S $HF) || die SETUP_NODE_API "the switch could not be re-checked after the ${HOLD}s hold (header id unreadable)"
  same=no; bl=$(f L bestFullHeaderId); [[ "$bl" != null && "$bl" == "$(f S bestFullHeaderId)" ]] && same=yes
  echo "[fc] after ${HOLD}s: L@fork=${lh:0:16} S@fork=${sh:0:16} same tip: $same"
  # main: L's switch is the effect measured, so one that did not hold is not counted. reverse: L's switch is the
  # unexpected outcome, so it stays reported even if L later went back.
  if [[ -n "$tL" ]] && ! [[ "$lh" == "$Y" && $same == yes ]]; then revL=$tL
    if [[ "$MODE" == main ]]; then tL=""; echo "[fc] L's switch at t+${revL}s did NOT hold ${HOLD}s: not counted"
    else echo "[fc] L's switch at t+${revL}s did not hold ${HOLD}s (still reported: in reverse any switch of L is unexpected)"; fi
  fi
  [[ -n "$tS" ]] && ! [[ "$sh" == "$X" && $same == yes ]] && { revS=$tS; tS=""; echo "[fc] S's switch at t+${revS}s did NOT hold ${HOLD}s: not counted"; }
fi
# the premise of a no-switch: L and S could talk. A run in which they never connected shows nothing about switching
# (not the same as L never receiving S's headers over a connection, which is the effect some builds show)
[[ $everc == 1 || -n "$tL$tS$revL$revS" ]] || die SETUP_NO_CONNECTION "L and S never connected after the link opened (${TMAX}s)"
W=$(( $(grep -c "Extension is empty while comparison is younger" "$WORKDIR/node_S.log") - W0 ))
WL=$(( $(grep -c "Extension is empty while comparison is younger" "$WORKDIR/node_L.log") - W0L ))
echo "[fc] 'Extension is empty while comparison is younger' after open: S=$W L=$WL"
echo "[fc] L rollbacks: $(grep -c 'Rollback UtxoState' "$WORKDIR/node_L.log")  S rollbacks: $(grep -c 'Rollback UtxoState' "$WORKDIR/node_S.log")"
if [[ "$MODE" == main ]]; then
  [[ -n "$tL" ]] && echo "RESULT main: L SWITCHED to the heavier fork at t+${tL}s (fork height $HF, margin $M)" \
                 || echo "RESULT main: L did NOT switch in ${TMAX}s (fork height $HF, margin $M)$([[ -n "$revL" ]] && echo "; a switch at t+${revL}s did not hold")"
else
  [[ -z "$tL" ]] && echo "RESULT reverse: L stayed on its heavier fork for ${TMAX}s (expected); S switched: $([[ -n "$tS" ]] && echo "yes at t+${tS}s" || echo no)" \
                 || echo "RESULT reverse: L SWITCHED to the lighter fork at t+${tL}s (unexpected)"
fi
# diffrun: nodes whose REST no longer answers after the measurement (recorded, does not void the run)
UNR=""; for n in A C L S; do [[ "$(f $n appVersion)" == null ]] && UNR+="$n "; done
[[ -n "$UNR" ]] && echo "[fc] unresponsive after the measurement: $UNR"
# diffrun: the one machine-readable result line (scenario contract, diffrun/README.md). switch_s: seconds from the
# L-S link opening to L's (held) switch, at the 5 s polling resolution; null when L did not switch within TMAX (a
# censored time, to be analysed as time-to-event, not as a plain number)
echo "RESULT_JSON $(jq -cn --arg jv "$JAVA_VERSION" --arg A "$VA" --arg C "$VC" --arg L "$VL" --arg S "$VS" --argjson u "$(wc -w <<< "$UNR")" \
  --arg mode "$MODE" --arg tL "$tL" --arg tS "$tS" --argjson hf "$HF" --argjson m "$M" --argjson w "$W" --argjson wl "$WL" \
  '{schema_version:1,scenario:("fork-convergence"+(if $mode=="reverse" then "-reverse" else "" end)),runtime:{java:$jv},versions:{A:$A,C:$C,L:$L,S:$S},
    metrics:{switched:($tL!=""),s_switched:($tS!=""),switch_s:(if $tL=="" then null else ($tL|tonumber) end),fork_height:$hf,margin:$m,warn_S:$w,warn_L:$wl,unresponsive_after:$u}}')"
echo "[fc] node logs: $WORKDIR/node_{A,C,L,S}.log"
