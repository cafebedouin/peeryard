# Exercises partition/heal and crash/revive on a 2-node network (A mines, B follows).
# 1) B syncs from A. 2) partition -> B freezes while A climbs. 3) heal -> B catches up.
# 4) crash B (SIGKILL) -> B down. 5) revive B while partitioned from A -> B's height can only come from its own
# disk. 6) heal -> B re-syncs past it.
pass=1; note(){ echo "[netsplit] $*"; }

note "floor: B syncs from A"
end=$((SECONDS+120)); while [ $SECONDS -lt $end ]; do
  bf=$(full_height B); af=$(full_height A); note "A=$af B=$bf"
  [ "${bf:-0}" -ge 4 ] && [ "$bf" = "$af" ] && break; sleep 4
done
[ "${bf:-0}" -ge 4 ] && note "floor OK (B=$bf)" || { note "floor FAIL"; pass=0; }

before=$(full_height B); note "partition A<->B at B=$before"
partition A B
sleep 20   # A keeps mining; B must not advance
bmid=$(full_height B); amid=$(full_height A)
note "during split: A=$amid B=$bmid"
{ [ "$bmid" = "$before" ] && [ "$amid" -gt "$before" ]; } && note "split OK: B frozen, A advanced" || { note "split FAIL"; pass=0; }

heal A B; note "healed; waiting for B to catch up (A keeps mining, so B tracks within a small lag)"
end=$((SECONDS+90)); while [ $SECONDS -lt $end ]; do
  bf=$(full_height B); af=$(full_height A); note "A=$af B=$bf"
  [ "${bf:-0}" -gt "$bmid" ] && [ $((af - bf)) -le 5 ] && break; sleep 4
done
{ [ "${bf:-0}" -gt "$bmid" ] && [ $((af - bf)) -le 5 ]; } && note "heal OK: B advanced past the frozen $bmid to $bf, lag $((af-bf))" || { note "heal FAIL (B=$bf A=$af, was frozen at $bmid)"; pass=0; }

pre=$(full_height B); note "crash B at height $pre"
crash B; sleep 3
rest B /info >/dev/null 2>&1 && { note "crash FAIL: B still answering"; pass=0; } || note "crash OK: B down"
partition A B; note "partitioned before the revive: B can restore only from its own disk"
revive B
# /info answers before the node view is loaded (fullHeight 0 for a few seconds), so wait for the height, not the first
# answer; cut from A, the only source of a height >= pre is B's own disk
end=$((SECONDS+60)); while [ $SECONDS -lt $end ]; do bf=$(full_height B); note "B after revive (cut from A)=${bf:-?}"; [ "${bf:-0}" -ge "$pre" ] && break; sleep 4; done
cb=$(rest B /peers/connected | jq -r 'length' 2>/dev/null)
{ [ "${bf:-0}" -ge "$pre" ] && [ "${cb:-1}" = 0 ]; } && note "revive OK: B restored $bf from disk (>= $pre before crash, no peer connected)" \
  || { note "revive FAIL: B=${bf:-?} (was $pre), connected=${cb:-?}"; pass=0; }
heal A B
end=$((SECONDS+90)); while [ $SECONDS -lt $end ]; do b2=$(full_height B); af=$(full_height A); note "after heal A=$af B=$b2"; [ "${b2:-0}" -gt "${bf:-0}" ] && break; sleep 4; done
[ "${b2:-0}" -gt "${bf:-0}" ] && note "re-sync OK: B advanced from $bf to $b2" || { note "re-sync FAIL: B stayed at ${b2:-?}"; pass=0; }

if [ "$pass" = 1 ]; then echo "NETSPLIT-RESULT: PASS"; rig_verdict=PASS; else echo "NETSPLIT-RESULT: FAIL"; rig_verdict=FAIL; fi
