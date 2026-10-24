# upgrade-restart: a node upgraded in place. M mines and U follows, both on the baseline jar (PEERYARD_JAR_B). U's
# wallet is a file-backed one (no test mnemonic: restored over the API with a password, so its encrypted secret is
# written by the baseline), and M pays it UPG_PAYMENTS times. Then U is cut from M, stopped (SIGTERM, the rig's
# relaunch), and started on the candidate jar (PEERYARD_JAR) over the same data directory. While still cut from M,
# so that nothing it reports can come from a peer:
#   version   U reports a different appVersion than before (the candidate really runs)
#   chain     U's full height is at least its height before the stop, with the same header id at that height
#   state     the state root of the header at that height is unchanged
#   wallet    the candidate unlocks the baseline's secret file with the same password, and the confirmed balance
#             is the one the baseline reported
# Then the cut is healed and U must make progress on the candidate: it catches up with M, spends from the upgraded
# wallet (the payment confirms: its confirmed balance drops), and settles level with M on one state root at least
# UPG_PROGRESS blocks above the height of the stop.
#   PEERYARD_JAR_B=<baseline.jar> PEERYARD_JAR=<candidate.jar> bash rig/rig.sh rig/examples/upgrade-restart.json rig/examples/upgrade-restart.sh
# PASS = every check above. INCONCLUSIVE when the setup did not happen (the two jars are one file, U never synced,
# the payments never confirmed before the stop, the cut did not hold).
#   UPG_PAYMENTS (3), UPG_NANOERG (100000000, 0.1 ERG each), UPG_MIN_HEIGHT (40: U's height before the stop),
#   UPG_PROGRESS (10)
NP=${UPG_PAYMENTS:-3}; AMT=${UPG_NANOERG:-100000000}; HMIN=${UPG_MIN_HEIGHT:-40}; PROG=${UPG_PROGRESS:-10}
PASS_WORD="upgrade-restart-pw"   # a local devnet wallet; the mnemonic is the public BIP-39 test vector
MNEM="abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
note(){ echo "[upgrade-restart] $*"; }
ver(){ rest "$1" /info | jq -r '.appVersion // "null"'; }
root_of(){ rest "$1" "/blocks/$2/header" | jq -r '.stateRoot // empty'; }
upg_end(){ echo "[upgrade-restart] === UPGRADE-RESTART: $1 ($2) ==="; rig_verdict=$1; }

upgrade_restart(){
  local cand base vb vm i id sent=0 need bal0 h0 hid0 root0 ver0 ver1 h1 hid1 root1 peers unl st bal1 b2 end fails=""
  cand="$(readlink -f "${PEERYARD_JAR:-}")"; base="$(readlink -f "${PEERYARD_JAR_B:-}")"
  [[ -n "${PEERYARD_JAR_B:-}" && -f "$base" && -f "$cand" ]] || { upg_end INCONCLUSIVE "needs PEERYARD_JAR_B (baseline) and PEERYARD_JAR (candidate)"; return; }
  [[ "$(sha256sum "$cand" | cut -d' ' -f1)" != "$(sha256sum "$base" | cut -d' ' -f1)" ]] || { upg_end INCONCLUSIVE "the baseline and candidate jars are the same file"; return; }
  vm=$(ver M); vb=$(ver U); note "baseline jar $(basename "$base") (M=$vm U=$vb), candidate jar $(basename "$cand")"
  [[ "$vb" != null && "$vb" == "$vm" ]] || { upg_end INCONCLUSIVE "U and M do not both report the baseline version (M=$vm U=$vb)"; return; }

  # 1. U follows M on the baseline, with a wallet whose secret file the baseline writes
  end=$((SECONDS + 150)); st=""
  while [[ $SECONDS -lt $end ]]; do st=$(same_chain M U); case "$st" in SAME@*) h1=${st#SAME@}; [[ "${h1%%:*}" -ge 5 ]] && break ;; esac; sleep 3; done
  case "$st" in SAME@*) note "U follows M: $(cut -c1-20 <<< "$st")" ;; *) upg_end INCONCLUSIVE "U never synced M on the baseline ($st)"; return ;; esac
  note "U wallet restore: $(wallet U /wallet/restore "{\"pass\":\"$PASS_WORD\",\"mnemonic\":\"$MNEM\",\"usePre1627KeyDerivation\":false}" | head -c 120)"
  wallet U /wallet/unlock "{\"pass\":\"$PASS_WORD\"}" > /dev/null
  [[ -n "$(address U)" && "$(address U)" != "$(address M)" ]] || { upg_end INCONCLUSIVE "U's restored wallet has no address of its own"; return; }
  note "U address $(address U); secret files: $(find "$SCRATCH/data_U" -path '*keystore*' -type f 2>/dev/null | wc -l)"
  need=$((AMT * NP * 4))
  wait_balance M "$need" 300 > /dev/null || { upg_end INCONCLUSIVE "M never reached $need nanoERG to pay with"; return; }
  for i in $(seq 1 "$NP"); do id=$(pay M U "$AMT"); if [[ "$id" =~ ^[0-9a-f]{64}$ ]]; then sent=$((sent + 1)); else note "payment $i rejected: ${id:0:120}"; fi; sleep 1; done
  [[ $sent == "$NP" ]] || { upg_end INCONCLUSIVE "$sent of $NP payments to U accepted"; return; }
  wait_balance U $((AMT * NP)) 240 > /dev/null || { upg_end INCONCLUSIVE "U's confirmed balance never reached $((AMT * NP))"; return; }
  end=$((SECONDS + 240)); while [[ $SECONDS -lt $end && "$(full_height U)" -lt "$HMIN" ]]; do sleep 3; done
  [[ "$(full_height U)" -ge "$HMIN" ]] || { upg_end INCONCLUSIVE "U did not reach height $HMIN on the baseline"; return; }

  # 2. cut, record what U holds, stop it and start it on the candidate over the same data directory
  partition M U || { upg_end INCONCLUSIVE "partition M U failed"; return; }
  sleep 4
  h0=$(full_height U); hid0=$(header_at U "$h0"); root0=$(root_of U "$hid0"); bal0=$(balance U); ver0=$(ver U)
  note "before the upgrade (cut from M): U height $h0, header ${hid0:0:16}, state root ${root0:0:16}, balance $bal0, appVersion $ver0"
  [[ -n "$hid0" && -n "$root0" && "${bal0:-0}" -ge $((AMT * NP)) ]] || { upg_end INCONCLUSIVE "could not read U's header, root or balance before the upgrade"; return; }
  NODE_JAR[U]="$cand"
  # the node reads fallback configs from its working directory: give it the candidate's copies (rig.sh does this at start)
  [[ -n "${RUNTIME_CWD:-}" ]] || unzip -o -q "$cand" application.conf devnet.conf mainnet.conf testnet.conf -d "${RT_CWD[U]}/src/main/resources"
  mark upgrade-stop
  relaunch U || { upg_end FAIL "U did not come back on the candidate"; return; }
  mark upgrade-started

  # 3. still cut: everything U reports comes from its own disk
  ver1=$(ver U); h1=$(full_height U); hid1=$(header_at U "$h0"); root1=$(root_of U "$hid1"); peers=$(rest U /peers/connected | jq -r 'length' 2>/dev/null)
  note "after the upgrade (cut from M): appVersion $ver1, height $h1, header at $h0 ${hid1:0:16}, root ${root1:0:16}, connected peers ${peers:-?}"
  [[ "${peers:-1}" == 0 ]] || { upg_end INCONCLUSIVE "U lists ${peers:-?} connected peers while cut from M"; return; }
  [[ "$ver1" != null && "$ver1" != "$ver0" ]] || fails+=" version($ver0->$ver1)"
  [[ "${h1:-0}" -ge "$h0" && "$hid1" == "$hid0" ]] || fails+=" chain(h $h0->$h1, id ${hid0:0:8}->${hid1:0:8})"
  [[ -n "$root1" && "$root1" == "$root0" ]] || fails+=" state(${root0:0:8}->${root1:0:8})"
  unl=$(wallet U /wallet/unlock "{\"pass\":\"$PASS_WORD\"}")
  st=$(wallet U /wallet/status | jq -c '{isInitialized, isUnlocked}' 2>/dev/null)
  note "unlock on the candidate: ${unl:0:120}; status $st"
  end=$((SECONDS + 90)); bal1=""; while [[ $SECONDS -lt $end ]]; do bal1=$(balance U); [[ "$bal1" == "$bal0" ]] && break; sleep 3; done
  note "balance on the candidate: $bal1 (baseline reported $bal0)"
  [[ "$(jq -r '.isUnlocked' <<< "$st" 2>/dev/null)" == true ]] || fails+=" wallet-unlock"
  [[ "$bal1" == "$bal0" ]] || fails+=" wallet-balance($bal0->$bal1)"

  # 4. healed: U catches up on the candidate, spends from the upgraded wallet, and settles with M
  heal M U
  end=$((SECONDS + 150)); st=""
  while [[ $SECONDS -lt $end ]]; do st=$(same_chain M U); case "$st" in SAME@*) h1=${st#SAME@}; [[ "${h1%%:*}" -gt "$h0" ]] && break ;; esac; sleep 3; done
  note "after the heal: $(cut -c1-24 <<< "$st"), M=$(full_height M) U=$(full_height U)"
  id=$(pay U M "$AMT"); note "payment from U's upgraded wallet: ${id:0:80}"
  b2=$bal0
  if [[ "$id" =~ ^[0-9a-f]{64}$ ]]; then
    end=$((SECONDS + 180)); while [[ $SECONDS -lt $end ]]; do b2=$(balance U); [[ "${b2:-0}" -le $((bal0 - AMT)) ]] && break; sleep 3; done
    note "U's confirmed balance after its payment: $b2 (before $bal0)"
    [[ "${b2:-0}" -le $((bal0 - AMT)) ]] || fails+=" spend-confirm"
  else fails+=" spend-accept"; fi
  if settle_follow M U $((h0 + PROG)) 180; then note "settled: ${SETTLE_STATE:0:24} after ${SETTLE_WAIT_S}s"
  else note "no settle: ${SETTLE_STATE:0:40}"; fails+=" progress(${SETTLE_STATE%%:*})"; fi
  if [[ -z "$fails" ]]; then upg_end PASS "chain, state and wallet kept across $ver0 -> $ver1; U at $(full_height U) on M's chain"
  else upg_end FAIL "failed:$fails"; fi
}
upgrade_restart
