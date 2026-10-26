# shellcheck shell=bash
# wallet-unlock-2828: one node whose wallet keeps its secret in a file (testMnemonic cleared, so /wallet/init writes
# the keystore file). The wallet is initialized and locked; the secret file is moved out of the keystore directory and
# /wallet/unlock is timed; the file is moved back and the wallet unlocked again, without a node restart; then the
# node is restarted and unlocked once more.
# RESULT_JSON metrics: unreadable_code, unreadable_s (the unlock with the file gone: HTTP status, seconds),
# initialized_after, unlocked_after (/wallet/status 10 s later), recovered (unlocked once the file is back),
# restart_initialized, restart_unlocked (after a node restart: status, then an unlock),
# pass = an error answer within 10 s, the wallet still initialized and locked, recovered, and initialized and
# unlocked after the restart.
P='peeryard-unlock'
ks="$SCRATCH/data_A/wallet/keystore"; aside="$SCRATCH/keystore-aside"
post_timed(){ ip netns exec "${NS[A]}" curl -s -o "$SCRATCH/post-body.txt" -w '%{http_code} %{time_total}' --max-time 120 \
  -X POST -H "api_key: $API_KEY" -H 'Content-Type: application/json' --data "$2" "http://127.0.0.1:${REST[A]}$1"; }
status(){ wallet A /wallet/status | jq -c '{isInitialized, isUnlocked, error}' 2>/dev/null; }

# the wallet answers only once the node is up (an error status before that): wait up to 60 s, then init (3 tries)
for _ in $(seq 1 30); do [[ "$(status | jq -r '.error // "x"' 2>/dev/null)" == "" ]] && break; sleep 2; done
for _ in 1 2 3; do
  init=$(wallet A /wallet/init "{\"pass\":\"$P\"}" | jq -r 'if .mnemonic then "ok" else tostring end' 2>/dev/null)
  [[ "$init" == ok ]] && break; sleep 5
done
wallet A /wallet/lock > /dev/null
echo "[unlock] init: ${init:-none}; after lock: $(status); keystore: $(ls "$ks" 2>/dev/null | tr '\n' ' ')"
mkdir -p "$aside"; moved=0
for f in "$ks"/*.json; do [[ -f "$f" ]] && mv "$f" "$aside/" && moved=$((moved + 1)); done
echo "[unlock] secret files moved aside: $moved"
if [[ "$init" != ok || $moved -lt 1 ]]; then
  # a harness failure (no wallet file to move): no RESULT_JSON, so the run is INCONCLUSIVE, not a result
  rig_verdict=INCONCLUSIVE; echo "[unlock] === WALLET-UNLOCK-2828: INCONCLUSIVE (init: ${init:-none}, files moved: $moved) ==="
  return 0
fi

read -r code secs <<< "$(post_timed /wallet/unlock "{\"pass\":\"$P\"}")"
echo "[unlock] unlock with the file gone: HTTP $code after ${secs}s, body: $(head -c 200 "$SCRATCH/post-body.txt" | tr '\n' ' ')"
echo "[unlock] status right after: $(status)"
sleep 10
st=$(status); echo "[unlock] status 10 s later: $st"
init_after=$(jq -r '.isInitialized // false' <<< "$st" 2>/dev/null); unl_after=$(jq -r '.isUnlocked // false' <<< "$st" 2>/dev/null)

for f in "$aside"/*.json; do [[ -f "$f" ]] && mv "$f" "$ks/"; done
read -r code2 secs2 <<< "$(post_timed /wallet/unlock "{\"pass\":\"$P\"}")"
st2=$(status)
echo "[unlock] file back: unlock HTTP $code2 after ${secs2}s, body: $(head -c 200 "$SCRATCH/post-body.txt" | tr '\n' ' '); status: $st2"
recovered=$(jq -r '.isUnlocked // false' <<< "$st2" 2>/dev/null)

# 5) a node restart, then unlock once more
relaunch A > /dev/null
# REST answers before the wallet is loaded (/wallet/status is an error then): wait up to 30 s for a status
for _ in $(seq 1 15); do st3=$(status); [[ "$(jq -r '.error // ""' <<< "$st3" 2>/dev/null)" == "" ]] && break; sleep 2; done
read -r code3 secs3 <<< "$(post_timed /wallet/unlock "{\"pass\":\"$P\"}")"; st4=$(status)
echo "[unlock] after a node restart: status $st3; unlock HTTP $code3 after ${secs3}s; status $st4"
r_init=$(jq -r '.isInitialized // false' <<< "$st3" 2>/dev/null); r_unl=$(jq -r '.isUnlocked // false' <<< "$st4" 2>/dev/null)

fast=false; awk -v s="${secs:-999}" 'BEGIN { exit !(s < 10) }' && [[ "${code:-0}" -ge 400 ]] && fast=true
pass=false; [[ $fast == true && "$init_after" == true && "$unl_after" != true && "$recovered" == true && "$r_init" == true && "$r_unl" == true ]] && pass=true
rig_verdict=$([[ $pass == true ]] && echo PASS || echo FAIL)
va=$(rest A /info | jq -r '.appVersion // "null"')
echo "RESULT_JSON $(jq -cn --arg v "$va" --argjson c "${code:-0}" --argjson s "${secs:-0}" --argjson i "$([[ $init_after == true ]] && echo true || echo false)" \
  --argjson u "$([[ $unl_after == true ]] && echo true || echo false)" --argjson r "$([[ $recovered == true ]] && echo true || echo false)" \
  --argjson ri "$([[ $r_init == true ]] && echo true || echo false)" --argjson ru "$([[ $r_unl == true ]] && echo true || echo false)" \
  --argjson p "$pass" --arg jv "$(${PEERYARD_JAVA:-java} -version 2>&1 | head -1)" \
  '{schema_version:1,scenario:"wallet-unlock-2828",runtime:{java:$jv},versions:{A:$v},metrics:{unreadable_code:$c,unreadable_s:$s,initialized_after:$i,unlocked_after:$u,recovered:$r,restart_initialized:$ri,restart_unlocked:$ru,pass:$p}}')"
echo "[unlock] === WALLET-UNLOCK-2828: $rig_verdict ==="
