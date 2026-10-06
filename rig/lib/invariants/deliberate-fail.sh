#!/usr/bin/env bash
# deliberate-fail.sh: a contract check for diag/block_invariants.py that fails on purpose, so a run can show that the
# per-block monitor reports a violation and that the violation reaches the verdict (a designed failing control; it
# tests the monitor, not the node). It fails on every block whose height is a multiple of DELIBERATE_FAIL_EVERY
# (default 1: every block) and holds on the others.
#   BLOCKWATCH_CONTRACTS=rig/lib/invariants/deliberate-fail.sh  (or blockwatch_stop --contract <this file>)
# Contract-check interface: the block (GET /blocks/<id>) on stdin, BLOCK_NODE / BLOCK_HEIGHT / BLOCK_ID in the
# environment; exit 0 = the invariant holds, anything else = violated, with the first output line as the reason.
set -uo pipefail
cat > /dev/null
every="${DELIBERATE_FAIL_EVERY:-1}"; [[ "$every" =~ ^[1-9][0-9]*$ ]] || { echo "DELIBERATE_FAIL_EVERY '$every': a positive integer"; exit 2; }
if (( BLOCK_HEIGHT % every == 0 )); then echo "deliberate test failure at height $BLOCK_HEIGHT (rig/lib/invariants/deliberate-fail.sh)"; exit 1; fi
exit 0
