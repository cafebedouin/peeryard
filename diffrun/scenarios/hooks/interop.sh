# shellcheck shell=bash
# interop hook: A (this role's jar) mines to 30 while B (the other jar) follows; B must settle level with A on the
# same state root (follow_ab). Then B mines 30 more while A follows; A settles (follow_ba).
# The settle is rig.sh's settle_follow: the miner drops to a slow poll, the follower must reach SAME@h (h >= target)
# between blocks, then the miner pauses. trickle_* counts the blocks mined during the settle; the settle line also
# prints same_state right after the pause (LAG@.. same-chain there: a block landed in the last seconds; not a failure).
# RESULT_JSON carries both appVersions and interop = follow_ab && follow_ba.
follow_settle(){ # follow_settle <miner> <follower> <target>: mine to target, settle; sets FS_OK, FS_TRICKLE, FS_WAIT
  local m=$1 f=$2 t=$3 end
  end=$((SECONDS + 240)); while [ $SECONDS -lt $end ] && [ "$(full_height "$m")" -lt "$t" ]; do sleep 3; done
  if settle_follow "$m" "$f" "$t" 150; then FS_OK=yes; else FS_OK=no; fi
  FS_TRICKLE=$SETTLE_TRICKLE; FS_WAIT=$SETTLE_WAIT_S
  echo "[interop] settle $m->$f: ${SETTLE_STATE%%:*} after ${FS_WAIT}s, $FS_TRICKLE block(s) mined during the settle; after the pause: ${SETTLE_AFTER%%:*}"; }
va=$(rest A /info | jq -r '.appVersion // "null"'); vb=$(rest B /info | jq -r '.appVersion // "null"')
echo "[interop] A=$va mines first, B=$vb follows"
follow_settle A B 30; ab=$FS_OK; tab=$FS_TRICKLE
echo "[interop] A mined to $(full_height A); B followed and settled: $ab ($(same_state A B | cut -d: -f1))"
h1=$(full_height A); start_mining B 1s >/dev/null
follow_settle B A $((h1 + 30)); ba=$FS_OK; tba=$FS_TRICKLE
echo "[interop] B mined to $(full_height B); A followed and settled: $ba ($(same_state A B | cut -d: -f1))"
unr=0; for n in A B; do [ "$(rest $n /info | jq -r '.appVersion // "null"')" = null ] && unr=$((unr + 1)); done
ok=false; [ "$ab" = yes ] && [ "$ba" = yes ] && ok=true
echo "RESULT_JSON $(jq -cn --arg A "$va" --arg B "$vb" --argjson ab "$([ "$ab" = yes ] && echo true || echo false)" --argjson ba "$([ "$ba" = yes ] && echo true || echo false)" --argjson ok "$ok" --argjson u "$unr" --argjson tab "${tab:-0}" --argjson tba "${tba:-0}" --arg jv "$(${PEERYARD_JAVA:-java} -version 2>&1 | head -1)" \
  '{schema_version:1,scenario:"interop",runtime:{java:$jv},versions:{A:$A,B:$B},metrics:{follow_ab:$ab,follow_ba:$ba,interop:$ok,trickle_ab:$tab,trickle_ba:$tba,unresponsive_after:$u}}')"
rig_verdict=$([ $ok = true ] && echo PASS || echo FAIL)
