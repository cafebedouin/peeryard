# mining self-test: mine about N blocks, check the node goes quiet, restart with mining on, then off again.
h0=$(full_height A); echo "[minetest] initial h=$h0"
mine A 3 8s
ha=$(full_height A); echo "[minetest] after mine(A,3): h=$ha"
sleep 6; hb=$(full_height A); sleep 6; hc=$(full_height A)
echo "[minetest] quiescence: h=$hb then h=$hc (equal => stopped OK)"
start_mining A 500ms; sleep 8; hd=$(full_height A)
echo "[minetest] after start_mining+8s: h=$hd (should climb from $hc)"
stop_mining A; sleep 4; he=$(full_height A); sleep 6; hf=$(full_height A)
echo "[minetest] re-quiescence: h=$he then h=$hf (equal => stopped OK)"
# every read must be a height (two empty reads would compare equal), and mine(A,3) must have advanced at least 3
num=yes; for v in "$h0" "$ha" "$hb" "$hc" "$hd" "$he" "$hf"; do [[ "$v" =~ ^[0-9]+$ ]] || num=no; done
if [ $num = no ]; then echo "[minetest] FAIL: a height read was empty ($h0 $ha $hb $hc $hd $he $hf)"; rig_verdict=FAIL
elif [ "$ha" -lt $((h0 + 3)) ]; then echo "[minetest] FAIL: mine(A,3) went from $h0 to $ha"; rig_verdict=FAIL
elif [ "$hb" = "$hc" ] && [ "$hd" -gt "$hc" ] && [ "$he" = "$hf" ]; then echo "[minetest] PASS: quiescent, climbs on start_mining, quiescent again"; rig_verdict=PASS; else echo "[minetest] FAIL: see the heights above"; rig_verdict=FAIL; fi
echo "MINETEST-DONE"
