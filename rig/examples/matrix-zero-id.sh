# matrix-zero-id: requests for the all-zero header id (Header.GenesisParentId, the parent of the genesis header) on the
# Matrix line. Three Matrix-line nodes in a line, A - B - C, no delay; A mines from genesis; B and C follow. A is
# deferred: B and C start and link first, then the hook launches A, which dials B, so the followers are connected when
# A mines the genesis block and receive it as an ordering-block announcement (the path that requests its parent).
#   PEERYARD_MATRIX_JAR=<weak-blocks jar> bash rig/rig.sh rig/examples/matrix-zero-id.json rig/examples/matrix-zero-id.sh
#   PEERYARD_DURATION seconds to observe (default 300); MATRIX_SAMPLE_S (default 20)
# After the observation, per follower log: the expired delivery checks for header 0…0 ("has not delivered network
# object 101 : 0…0", one per delivery timeout while the request stays open), the view holder's "Requested parent
# header 0…0" lines, and every expired delivery check (any id, for scale). Heights are sampled while A mines; at the
# end B and C are given up to 60 s to reach A's height. genesis_announced = followers that logged processing an
# ordering-block announcement for A's height-1 header (the trigger; 0 means the genesis reached them by sync instead).
# PASS = no follower requested header 0…0 and both reached A's height. INCONCLUSIVE: A below height 10, or no follower
# received the genesis as an announcement (a 0 count would then say nothing).
# Under diffrun (DIFFRUN_ROLE set; diffrun/scenarios/matrix-zero-id.json) the hook also prints one RESULT_JSON.
DUR=${PEERYARD_DURATION:-300}; SAMPLE=${MATRIX_SAMPLE_S:-20}
Z=0000000000000000000000000000000000000000000000000000000000000000
launch A && wait_up A || { echo "[matrix-zero-id] INCONCLUSIVE: A did not come up"; rig_verdict=INCONCLUSIVE; return; }
VA=$(rest A /info | jq -r .appVersion); VB=$(rest B /info | jq -r .appVersion); VC=$(rest C /info | jq -r .appVersion)
echo "[matrix-zero-id] A=$VA B=$VB C=$VC; observing ${DUR} s"
t0=$SECONDS
while [ $((SECONDS - t0)) -lt "$DUR" ]; do
  sleep "$SAMPLE"
  echo "  t+$((SECONDS - t0))s A.h=$(full_height A) B.h=$(full_height B) C.h=$(full_height C)"
done
ha=$(full_height A); caught=false
for _ in $(seq 1 30); do
  hb=$(full_height B); hc=$(full_height C)
  [[ "$hb" -ge "$ha" && "$hc" -ge "$ha" ]] && { caught=true; break; }
  sleep 2
done
echo "[matrix-zero-id] end: A.h=$ha B.h=$hb C.h=$hc followers_caught_up=$caught"
cnt(){ local c; c=$(grep -cF -- "$2" "$RIG_LOG_DIR/node_$1.log" 2>/dev/null); echo "${c:-0}"; }
gid=$(rest A /blocks/at/1 | jq -r '.[0] // empty')
declare -A UZ RZ UA GA
for n in A B C; do
  GA[$n]=0; [[ -n "$gid" ]] && GA[$n]=$(cnt "$n" "Processing ordering block announcement for $gid")
  UZ[$n]=$(cnt "$n" "has not delivered network object 101 : $Z")
  RZ[$n]=$(cnt "$n" "Requested parent header $Z")
  UA[$n]=$(cnt "$n" "has not delivered network object")
  echo "[matrix-zero-id] $n zero_undelivered=${UZ[$n]} zero_parent_requested=${RZ[$n]} undelivered_any=${UA[$n]} genesis_announcements=${GA[$n]}"
done
zu=$((UZ[B] + UZ[C])); zr=$((RZ[B] + RZ[C])); ga=0
for n in B C; do [[ ${GA[$n]} -gt 0 ]] && ga=$((ga + 1)); done
echo "[matrix-zero-id] genesis ${gid:-?}: received as an announcement by $ga of 2 followers"
if [[ ! "$ha" =~ ^[0-9]+$ || $ha -lt 10 ]]; then
  echo "[matrix-zero-id] INCONCLUSIVE: A reached height ${ha:-?} < 10"; rig_verdict=INCONCLUSIVE; return
fi
if [[ $ga -eq 0 ]]; then
  echo "[matrix-zero-id] INCONCLUSIVE: no follower received the genesis as an ordering-block announcement"; rig_verdict=INCONCLUSIVE; return
fi
res=FAIL; [[ $zu -eq 0 && $zr -eq 0 && $caught == true ]] && res=PASS
rig_verdict=$res; echo "[matrix-zero-id] === MATRIX-ZERO-ID: $res ==="
if [[ -n "${DIFFRUN_ROLE:-}" ]]; then
  echo "RESULT_JSON $(jq -cn --arg A "$VA" --arg B "$VB" --arg C "$VC" --argjson zu "$zu" --argjson zr "$zr" \
    --argjson bu "${UZ[B]}" --argjson cu "${UZ[C]}" --argjson ua "$((UA[B] + UA[C]))" --argjson ha "$ha" --argjson up "$caught" --argjson ga "$ga" \
    '{schema_version: 1, scenario: "matrix-zero-id", versions: {A: $A, B: $B, C: $C},
      metrics: {zero_undelivered: $zu, zero_parent_requested: $zr, b_zero_undelivered: $bu, c_zero_undelivered: $cu,
                undelivered_any: $ua, a_height: $ha, followers_caught_up: $up, genesis_announced: $ga}}')"
fi
