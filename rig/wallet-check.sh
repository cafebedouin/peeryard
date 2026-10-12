#!/usr/bin/env bash
# wallet-check.sh: judge wallet-workload observations without a node (the same judgement a run makes,
# rig/lib/wallet_check.jq). Each file holds one observation per line, or one JSON object; a run keeps them as
# $RIG_LOG_DIR/wallet-workload/obs_NN.json, so a run can be re-judged offline:
#   bash rig/wallet-check.sh <obs.json>...
# Prints one line per step and per invariant, then the verdict line. Exit 0 on PASS (or CONTROL-TRIPPED: a positive
# control failed as it must), 1 on FAIL (or CONTROL-NOT-TRIPPED), 3 on INCONCLUSIVE, 2 on unreadable input.
# WALLET_CHECK_LIB=<dir> judges with another copy of wallet_check.jq (the self-test's falsifier).
set -uo pipefail
LIB="${WALLET_CHECK_LIB:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib}"
[[ $# -gt 0 ]] || { sed -n '2,9p' "$0" >&2; exit 2; }
judged=$(jq -c -L "$LIB" 'include "wallet_check"; judge' "$@" 2>&1) || { echo "wallet-check: unreadable input: ${judged:0:200}"; exit 2; }
jq -r '"[ww] step \(.step) \(.kind)\(if .arg then ":" + .arg else "" end): \(.verdict)\(if .setup then " (" + .setup + ")" else "" end)",
       (.invariants[] | "[ww]     \(if .ok then "ok  " else "FAIL" end) \(.name): \(.value)")' <<< "$judged"
sum=$(jq -sc -L "$LIB" 'include "wallet_check"; summarize' <<< "$judged")
v=$(jq -r .verdict <<< "$sum")
echo "WALLET-CHECK: $v $(jq -c 'del(.verdict)' <<< "$sum")"
case "$v" in PASS|CONTROL-TRIPPED) exit 0 ;; INCONCLUSIVE) exit 3 ;; *) exit 1 ;; esac
