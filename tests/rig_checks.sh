#!/usr/bin/env bash
# shellcheck disable=SC2030,SC2031  # each case runs in a subshell of its own on purpose: its stubs and state stay there
# rig_checks.sh: no-node tests of rig checks and helpers, each against stubs: rig.sh's topology validation
# (rig/lib/topology.sh; rig.sh run on broken copies of a topology, with stub tools on PATH so a run that passes the
# validation is caught at its first `unshare`, before any namespace), partition/heal's per-direction PARTITIONED flags
# and check_topology's reading of them, settle_follow's SETTLE_TRICKLE on unread heights, the background-helper
# registry (rig/lib/bg.sh) as stop_all walks it, and the example hooks relay-floor (env refusal), poscontrol (verdict
# per same_chain token), crash-consistency (wait_backlog) and the foreign follow hooks (rig/lib/foreign_follow.sh).
# Run from the peeryard root:
#   T=$(mktemp -d) bash tests/rig_checks.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2
command -v jq >/dev/null 2>&1 || { echo "tests/rig_checks.sh needs jq; not run" >&2; exit 2; }
T="${T:?set T to a scratch dir, e.g. T=$(mktemp -d)}"
# T is deleted and recreated below: refuse anything that is not a scratch dir under /tmp or $TMPDIR (where
# mktemp -d puts one), and anything that contains the current directory (T=. from the repo root).
Tr="$(realpath -m -- "$T")"; Tmpr="$(realpath -m -- "${TMPDIR:-/tmp}")"
case "$Tr/" in /tmp/?*/|"$Tmpr"/?*/) ;; *) echo "refusing T='$T': not a scratch dir under /tmp or \$TMPDIR (use T=\$(mktemp -d))" >&2; exit 2 ;; esac
case "$PWD/" in "$Tr"/*) echo "refusing T='$T': it contains the current directory" >&2; exit 2 ;; esac
rm -rf "$T"; mkdir -p "$T"
fail=0
ok(){ printf '%-74s ok\n' "$1"; }
bad(){ printf '%-74s MISMATCH (%s)\n' "$1" "$2"; fail=1; }
expect_eq(){ [[ "$2" == "$3" ]] && ok "$1" || bad "$1" "want '$2', got '$3'"; }
expect_in(){ grep -qF -- "$2" "$3" && ok "$1" || bad "$1" "no '$2' in $3: $(head -c 300 "$3")"; }
expect_not_in(){ grep -qF -- "$2" "$3" && bad "$1" "'$2' in $3" || ok "$1"; }

# ---- rig.sh topology validation: every problem named, exit 2, and no `unshare` reached ----
A="$T/art"; mkdir -p "$A/bin"; : > "$A/j.jar"; printf '#!/bin/sh\nexit 0\n' > "$A/node-bin"; chmod +x "$A/node-bin"
# stub tools: rig.sh only asks `command -v` for curl, unzip, ip and tc before the validation; unshare records a call
for t in curl unzip ip tc; do printf '#!/bin/sh\nexit 0\n' > "$A/bin/$t"; done
printf '#!/bin/sh\necho "$*" >> "%s/unshare.calls"\nexit 1\n' "$T" > "$A/bin/unshare"; chmod +x "$A/bin/"*
V="$T/topo"; mkdir -p "$V"; base=rig/examples/bringup.json
rigv(){ local name="$1"; rm -f "$T/unshare.calls"
  PATH="$A/bin:$PATH" PEERYARD_JAVA=true PEERYARD_JAR="$A/j.jar" PEERYARD_CHAIN='' SCRATCH="$V/scratch-$name" \
    bash rig/rig.sh "$V/$name.json" rig/examples/bringup.sh > "$V/$name.out" 2>&1; echo $?; }
vcase(){ local name="$1" prog="$2" want="$3" rc
  if [[ "$prog" == RAW:* ]]; then printf '%s' "${prog#RAW:}" > "$V/$name.json"; else jq "$prog" "$base" > "$V/$name.json"; fi
  rc=$(rigv "$name")
  if [[ $rc == 2 ]] && grep -qF -- "FAIL: topology $V/$name.json: $want" "$V/$name.out" && [[ ! -e "$T/unshare.calls" ]] && ! grep -q '^\[rig\] scratch:' "$V/$name.out"
  then ok "validate: $name -> exit 2 before unshare"
  else bad "validate: $name" "exit $rc, unshare $([[ -e "$T/unshare.calls" ]] && echo reached || echo 'not reached'); want '$want' in: $(head -c 300 "$V/$name.out")"; fi; }
vcase link-b-unknown '.links[0].b = "X"' "unknown node 'X' in links[0].b"
vcase link-a-missing 'del(.links[0].a)' "links[0].a is missing or not a string"
vcase self-link '.links[0].b = .links[0].a' "links[0] joins node 'A' to itself"
vcase dup-link '.links += [{"a": .links[0].b, "b": .links[0].a}]' "links[1] repeats links[0] (A<->B): one link per pair of nodes"
vcase links-not-list '.links = {"a": "A"}' "links is not a list"
vcase dup-name '.nodes[1].name = .nodes[0].name' "node name 'A' appears 2 times (nodes[0,1])"
vcase bad-name '.nodes[0].name = "TOOLONG"' "node name 'TOOLONG' (nodes[0]) must be 1-5 letters or digits"
vcase node-not-object '.nodes[1] = "B"' "nodes[1] is not an object"
vcase nodes-empty '.nodes = []' "nodes is missing or not a non-empty list"
vcase not-json 'RAW:{"nodes": [' "not valid JSON"
vcase peer-unknown '.nodes[1].knownPeers = ["A", "Z"]' "unknown peer 'Z' in nodes[1].knownPeers[1] (node 'B'"
vcase peers-not-list '.nodes[1].knownPeers = "A"' "knownPeers in node 'B' is not a list: \"A\""
vcase bad-kind '.nodes[1].kind = "geth"' "node B: unknown kind 'geth'"
vcase rust-no-preset ".nodes[1].kind = \"arkadianet\" | .nodes[1].bin = \"$A/node-bin\"" "node B is kind arkadianet; a non-jvm node needs the chain preset rust-devnet"
vcase jopts-rust ".chain = \"rust-devnet\" | .nodes[1].kind = \"arkadianet\" | .nodes[1].bin = \"$A/node-bin\" | .nodes[1].java_opts = \"-Xmx1g\"" "node B: java_opts is for jvm nodes only (kind arkadianet)"
vcase bin-missing '.chain = "rust-devnet" | .nodes[1].kind = "ergo-node-rust" | .nodes[1].bin = "/nonexistent/bin"' "no node binary for B (kind ergo-node-rust)"
# shellcheck disable=SC2016  # a literal ${VAR} in the topology
vcase bin-unset-var '.chain = "rust-devnet" | .nodes[1].kind = "ergo-node-rust" | .nodes[1].bin = "${RIG_CHECKS_UNSET}"' "node B: bin is '\${RIG_CHECKS_UNSET}' but expands to nothing"
vcase jar-missing '.nodes[1].jar = "/nonexistent.jar"' "no node jar for B"
# shellcheck disable=SC2016
vcase jar-unset-var '.nodes[1].jar = "${RIG_CHECKS_UNSET}"' "node B: jar is '\${RIG_CHECKS_UNSET}' but expands to nothing"
vcase cpus-syntax '.nodes[0].cpus = "0-"' "node A: cpus '0-' is not a CPU list"
vcase cpus-outside '.nodes[0].cpus = "4000"' "cpus outside rig affinity: node=A requested=4000"
vcase bad-preset '.chain = "mainnet"' "unknown chain preset 'mainnet'"
vcase several '.links[0].b = "X" | .nodes[1].knownPeers = ["Q"]' "unknown peer 'Q'"
expect_in "validate: ... and the other problem of that topology too" "unknown node 'X' in links[0].b" "$V/several.out"
# a binary named by nodes[].bin with no jar (the old outer check read the tab-separated fields shifted, the bin as a jar)
jq ".chain = \"rust-devnet\" | .nodes[1].kind = \"arkadianet\" | .nodes[1].bin = \"$A/node-bin\"" "$base" > "$V/rust-bin.json"
rc=$(PEERYARD_ARKADIANET_BIN='' rigv rust-bin)
[[ -e "$T/unshare.calls" ]] && ok "validate: a valid topology (nodes[].bin, no env var) reaches unshare" || bad "validate: rust-bin" "exit $rc: $(head -c 300 "$V/rust-bin.out")"
cp "$base" "$V/valid.json"; rc=$(rigv valid)
[[ -e "$T/unshare.calls" ]] && ok "validate: bringup.json unchanged reaches unshare (the stub's refusal: exit $rc)" || bad "validate: valid" "exit $rc: $(head -c 300 "$V/valid.out")"
# every shipped topology passes, with stand-ins for the artifacts it names
( for v in PEERYARD_JAR PEERYARD_JAR_B PEERYARD_JAR_C PEERYARD_JAR_F1 PEERYARD_JAR_F2 PEERYARD_MATRIX_JAR; do export "$v=$A/j.jar"; done
  export PEERYARD_ARKADIANET_BIN="$A/node-bin" PEERYARD_ERGO_NODE_RUST_BIN="$A/node-bin" PEERYARD_CHAIN=''
  # shellcheck source=rig/lib/topology.sh
  source rig/lib/topology.sh; n=0; refused=0
  for f in rig/examples/*.json; do n=$((n + 1))
    # shellcheck disable=SC2016  # a jq program
    dj=$(jq -r --arg d "$PEERYARD_JAR" '(.jar // $d) | gsub("\\$\\{(?<v>[A-Za-z_][A-Za-z0-9_]*)\\}"; ($ENV[.v] // ""))' "$f")
    validate_topology "$f" "$dj" 2>> "$T/shipped.err" || refused=$((refused + 1)); done
  echo "$n $refused" ) > "$T/shipped.out"
read -r ns nr < "$T/shipped.out"
[[ "$nr" == 0 && "$ns" -gt 50 ]] && ok "validate: all $ns shipped topologies pass" || bad "validate: shipped topologies" "$nr of $ns refused: $(head -3 "$T/shipped.err")"

# ---- partition / heal: per-direction flags, set or cleared right after each direction's own change ----
( # shellcheck source=rig/lib/hook_api.sh
  source rig/lib/hook_api.sh
  declare -A LINK_OF=([A,B]=0 [B,A]=0) PARTITIONED=() CONFIGURED=([A,B]="" [B,A]="")
  harness_fail(){ echo "[rig] HARNESS-FAIL $1"; }; rig_event(){ :; }
  _netem(){ [[ "$1,$2" == "${FAIL_DIR:-}" ]] && { harness_fail "netem '$3' on $1->$2 not applied"; return 1; }; return 0; }
  flags(){ echo "$1 rc=$2 AB=${PARTITIONED[A,B]:-0} BA=${PARTITIONED[B,A]:-0}"; }
  FAIL_DIR=B,A partition A B > /dev/null; flags partition-half $?
  FAIL_DIR=A,B partition A B > /dev/null; flags partition-first-fails $?   # nothing changed, A->B still flagged from before
  partition A B > /dev/null; flags partition $?
  FAIL_DIR=B,A heal A B > /dev/null; flags heal-half $?
  heal A B > /dev/null; flags heal $?
  # check_topology (rig.sh) counts a link as partitioned while either direction is flagged
  eval "$(awk '/^check_topology\(\)\{/{f=1} f{print} f && /return \$ok; \}$/{exit}' rig/rig.sh)"
  LINK_A=(A); LINK_B=(B); NODES=(A B); peers_of(){ :; }
  PARTITIONED=([B,A]=1); check_topology; echo "check_topology rc=$?" ) > "$T/ph.out" 2>&1
expect_in "partition: second direction fails -> only the first flagged" "partition-half rc=1 AB=1 BA=0" "$T/ph.out"
expect_in "partition: first direction fails -> no flag changes" "partition-first-fails rc=1 AB=1 BA=0" "$T/ph.out"
expect_in "partition: both directions -> both flagged" "partition rc=0 AB=1 BA=1" "$T/ph.out"
expect_in "heal: second direction fails -> only the first cleared" "heal-half rc=1 AB=0 BA=1" "$T/ph.out"
expect_in "heal: both directions -> both cleared" "heal rc=0 AB=0 BA=0" "$T/ph.out"
expect_in "check_topology: link with only its B->A direction flagged -> partitioned" "link A<->B: partitioned (not expected connected)" "$T/ph.out"
expect_in "check_topology: ... and no MISSING for it" "check_topology rc=0" "$T/ph.out"

# ---- settle_follow: SETTLE_TRICKLE from re-read heights; -1 when a height stays unread, never the whole height ----
stf(){ ( # shellcheck source=rig/lib/hook_api.sh
  source rig/lib/hook_api.sh
  printf '%s\n' "$@" > "$T/stf.seq"; : > "$T/stf.n"
  # full_height prints the next value of the sequence ("-" = a REST miss: nothing, status 7); the last one repeats
  full_height(){ local n v; n=$(( $(wc -l < "$T/stf.n") + 1 )); echo >> "$T/stf.n"; v=$(sed -n "${n}p" "$T/stf.seq"); [[ -n "$v" ]] || v=$(tail -1 "$T/stf.seq")
    [[ "$v" == - ]] && return 7; echo "$v"; }
  start_mining(){ :; }; stop_mining(){ :; }; settle_height_back(){ :; }; sleep(){ :; }; same_state(){ echo "SAME@32:r"; }
  settle_follow L F 30 5; echo "rc=$? trickle=$SETTLE_TRICKLE" ) > "$T/stf.out" 2>&1; cat "$T/stf.out"; }
expect_eq "settle_follow: h0 missed once, re-read 30, ends at 32 -> trickle 2" "trickle=2" "$(stf - 30 32 | grep -o 'trickle=.*')"
expect_eq "settle_follow: both heights read -> trickle 2" "trickle=2" "$(stf 30 32 | grep -o 'trickle=.*')"
expect_eq "settle_follow: h0 never read -> trickle -1 (not 32)" "trickle=-1" "$(stf - - - - - - - 32 | grep -o 'trickle=.*')"
expect_in "settle_follow: ... and says so" "L's full height unread before the settle" "$T/stf.out"

# ---- background-helper registry: stop_all stops every registered helper, then any unregistered job, and returns ----
cat > "$T/sa.sh" <<'EOF'
set -uo pipefail
source rig/lib/bg.sh
eval "$(awk '/^stop_all\(\)/{f=1} f{print} f && /^  wait 2>\/dev\/null/{exit}' rig/rig.sh)"
NODES=(); declare -A PID=(); SCRATCH=/nonexistent; planned_exit(){ :; }
own_stop(){ echo "own_stop $1"; kill "$1"; wait "$1" 2>/dev/null; bg_unregister "$1"; }
( while :; do sleep 0.2; done ) & bg_register $! sampler
( trap '' TERM; while :; do sleep 0.2; done ) & bg_register $! stubborn
( while :; do sleep 0.2; done ) & p=$!; bg_register "$p" capture own_stop "$p"
( while :; do sleep 0.2; done ) & BG_PIDS+=($!)
( sleep 0.1 ) & q=$!; bg_register "$q" short; wait "$q"; bg_unregister "$q"
( while :; do sleep 0.2; done ) &
BG_STOP_GRACE_S=1 stop_all; echo "left=${#BG_PIDS[@]} swept=$BG_UNREGISTERED running=$(jobs -rp | wc -l)"
EOF
timeout 30 bash "$T/sa.sh" > "$T/sa.out" 2>&1; rc=$?
expect_eq "bg registry: stop_all returns (no hang in its wait)" 0 "$rc"
expect_in "bg registry: plain helpers stopped, a TERM-ignoring one killed" "background helpers stopped (plain): sampler(" "$T/sa.out"
expect_in "bg registry: ... the stubborn one too" "stubborn(" "$T/sa.out"
expect_in "bg registry: a helper with its own stop runs it after the nodes" "background helpers stopped (own): capture(" "$T/sa.out"
expect_in "bg registry: an unregistered job is named and killed" "was not registered (bg_register): killed" "$T/sa.out"
expect_in "bg registry: ... nothing left registered or running" "left=0 swept=1 running=0" "$T/sa.out"

# ---- relay-floor: an env the verdict cannot be reached with is refused before anything is sent ----
rf(){ ( RIG_LOG_DIR="$T/rf"; SCRATCH="$T/rf"; mkdir -p "$RIG_LOG_DIR"; : > "$T/rf.calls"
  rest(){ echo "rest $*" >> "$T/rf.calls"; }; address(){ echo "address $*" >> "$T/rf.calls"; }; mark(){ :; }; bg_register(){ :; }
  sleep(){ SECONDS=$((SECONDS + 100)); }
  env_kv=("$@"); for kv in "${env_kv[@]}"; do export "${kv?}"; done
  # shellcheck source=rig/examples/relay-floor.sh
  source rig/examples/relay-floor.sh
  echo "verdict=${rig_verdict:-} cause=${rig_cause:-}" ) > "$T/rf.out" 2>&1; }
rf RELAY_FLOOR_LOW=10 RELAY_FLOOR_VALID=20
expect_in "relay-floor: VALID above LOW -> INCONCLUSIVE BAD_ENV" "verdict=INCONCLUSIVE cause=BAD_ENV" "$T/rf.out"
expect_in "relay-floor: ... says why" "RELAY_FLOOR_VALID=20 is above RELAY_FLOOR_LOW=10" "$T/rf.out"
[[ ! -s "$T/rf.calls" ]] && ok "relay-floor: ... before any REST call" || bad "relay-floor: refused env" "calls: $(head -3 "$T/rf.calls")"
rf RELAY_FLOOR_LOW=5 RELAY_FLOOR_QVALID=10
expect_in "relay-floor: QVALID above LOW -> BAD_ENV" "RELAY_FLOOR_QVALID=10 is above RELAY_FLOOR_LOW=5" "$T/rf.out"
rf RELAY_FLOOR_VALID=x RELAY_FLOOR_INTERVALS=3
expect_in "relay-floor: a non-number -> BAD_ENV" "RELAY_FLOOR_VALID='x' is not a whole number" "$T/rf.out"
rf RELAY_FLOOR_INTERVALS=3
expect_in "relay-floor: 3 intervals -> BAD_ENV (the floor needs 4)" "RELAY_FLOOR_INTERVALS=3: the activity floor needs 4" "$T/rf.out"
rf RELAY_FLOOR_VALID=4
expect_in "relay-floor: 4 valid x 8 intervals < 40 -> BAD_ENV" "RELAY_FLOOR_VALID=4 x 8 intervals is below the 40" "$T/rf.out"
rf RELAY_FLOOR_QVALID=0
expect_not_in "relay-floor: QVALID=0 passes the env check (as VALID=0 does)" "BAD_ENV" "$T/rf.out"
expect_in "relay-floor: ... and goes on to the wallets" "a wallet never reported an address" "$T/rf.out"
rf RELAY_FLOOR_VALID=0 RELAY_FLOOR_LOW=120
expect_not_in "relay-floor: floor-spam's env (VALID=0 LOW=120) passes" "BAD_ENV" "$T/rf.out"

# ---- poscontrol: DIFF passes, SAME fails, a comparison not made (or peers unread) is INCONCLUSIVE with a cause ----
pc(){ ( sc="$1" peers="$2"; full_height(){ echo 5; }; sleep(){ :; }; same_chain(){ echo "$sc"; }
  rest(){ [[ "$peers" == miss ]] && return 7; echo "$peers"; }
  # shellcheck source=rig/examples/poscontrol.sh
  source rig/examples/poscontrol.sh > /dev/null; echo "${rig_verdict:-}/${rig_cause:-}" ); }
expect_eq "poscontrol: DIFF -> PASS" "PASS/" "$(pc 'DIFF@5:A=a:B=b' '[]')"
expect_eq "poscontrol: SAME -> FAIL" "FAIL/" "$(pc 'SAME@5:a' '[]')"
expect_eq "poscontrol: NOHEIGHT -> INCONCLUSIVE NO_HEIGHT" "INCONCLUSIVE/NO_HEIGHT" "$(pc NOHEIGHT '[]')"
expect_eq "poscontrol: NOID@ -> INCONCLUSIVE NO_HEADER_ID" "INCONCLUSIVE/NO_HEADER_ID" "$(pc 'NOID@5:A=:B=b' '[]')"
expect_eq "poscontrol: peer lists unread -> INCONCLUSIVE PEERS_UNREAD" "INCONCLUSIVE/PEERS_UNREAD" "$(pc 'DIFF@5:A=a:B=b' miss)"
expect_eq "poscontrol: peered -> INCONCLUSIVE NOT_ISOLATED" "INCONCLUSIVE/NOT_ISOLATED" "$(pc 'DIFF@5:A=a:B=b' '[{"name":"B"}]')"

# ---- crash-consistency wait_backlog: a backlog not reached (or M unread) is a staging failure, with the heights ----
wb(){ ( mode="$1"; STAGE_FAIL=(); stage_fail(){ STAGE_FAIL+=("$1"); echo "[cc] STAGING: $1"; }; BACKLOG=60
  eval "$(awk '/^wait_backlog\(\)/{f=1} f{print} f && /return 1; }$/{exit}' rig/examples/crash-consistency.sh)"
  full_height(){ case "$mode,$1" in miss,*) return 7 ;; ok,M) echo 70 ;; *,M) echo 10 ;; *,S) echo 5 ;; esac; }
  sleep(){ SECONDS=$((SECONDS + 100)); }
  wait_backlog 5; echo "rc=$? staging=${#STAGE_FAIL[@]}" ) > "$T/wb.out" 2>&1; }
wb stuck; expect_in "crash-consistency: backlog never reached -> STAGING with heights" "M at full height 10 after 300 s, below 65 (base 5 + CC_BACKLOG 60; S at 5)" "$T/wb.out"
expect_in "crash-consistency: ... rc 1, one staging failure" "rc=1 staging=1" "$T/wb.out"
wb miss; expect_in "crash-consistency: M unread -> waits, then STAGING (not reached at once)" "M at full height unread after 300 s" "$T/wb.out"
wb ok; expect_in "crash-consistency: backlog reached -> rc 0, no staging failure" "rc=0 staging=0" "$T/wb.out"

# ---- the foreign follow hooks: one body (rig/lib/foreign_follow.sh), each hook its own label and marker ----
cat > "$T/ff.sh" <<'EOF'
set -uo pipefail
C=$(mktemp); echo 0 > "$C"; tick(){ local n; n=$(( $(cat "$C") + 1 )); echo $n > "$C"; echo $n; }
declare -A NODE_JAR=([A]=/x/ergo.jar [B]=/x/node-bin)
rest(){ case "$1 $2" in "A /info") echo '{"appVersion":"6.0.8"}' ;; "B /info") echo "{\"appVersion\":\"${VB:-0.9.0}\",\"network\":\"devnet\",\"fullHeight\":$(( $(cat "$C") * 3 )),\"headersHeight\":$(( $(cat "$C") * 3 )),\"peersCount\":1}" ;;
  *"/blocks/at/1") echo '["g"]' ;; *"/peers/connected") echo '[{"name":"X","address":"/1.2.3.4:9","connectionType":"Incoming"}]' ;; esac; }
full_height(){ echo $(( $(tick) * 3 )); }
same_chain(){ echo "SAME@$(( $(cat "$C") * 3 )):id"; }; same_state(){ echo "SAME@45:root"; }
stop_mining(){ echo "[mine] stop_mining($1)"; }; check_topology(){ echo "  link A<->B: connected both ways"; }; sleep(){ :; }
source "$1"; echo "verdict=$rig_verdict"; rm -f "$C"
EOF
for h in arkadianet-follow:ARKADIANET-FOLLOW:arkadianet ergo-node-rust-follow:ERGO-NODE-RUST-FOLLOW:ergo-node-rust ergo-node-rust-follow-magic:ERGO-NODE-RUST-FOLLOW:ergo-node-rust; do
  IFS=: read -r name mk kind <<< "$h"
  bash "$T/ff.sh" "rig/examples/$name.sh" > "$T/ff-$name.out" 2>&1
  expect_in "$name: suite marker '$mk: PASS'" "$mk: PASS" "$T/ff-$name.out"
  expect_in "$name: ... its DONE line and B's kind" "B ($kind) appVersion=0.9.0" "$T/ff-$name.out"
  grep -q "^$mk-DONE$" "$T/ff-$name.out" && ok "$name: ... $mk-DONE" || bad "$name: DONE line" "$(tail -2 "$T/ff-$name.out")"
done
VB=6.0.8 bash "$T/ff.sh" rig/examples/arkadianet-follow.sh > "$T/ff-same.out" 2>&1
expect_in "arkadianet-follow: one appVersion on both -> FAIL" "=== ARKADIANET-FOLLOW: FAIL" "$T/ff-same.out"

[[ $fail == 0 ]] && echo "rig check tests: all ok" || { echo "rig check tests: MISMATCH (see $T)"; exit 1; }
