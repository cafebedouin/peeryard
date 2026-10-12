# wallet-workload: a scripted wallet workload with an invariant check after every step (rig/WALLET-WORKLOAD.md).
# M mines and funds one wallet, restored on two nodes (A and B: one testMnemonic, one derivation); the steps run
# through the node REST API: concurrent sends, token issue / transfer / burn, a scan the wallet must not spend from,
# the fee-estimation endpoints, one signed transaction resubmitted to a second node, and conflicting spends of one box
# built by the wallet on A and on B. Each step's observation is judged by rig/lib/wallet_check.jq; the run prints
# one line per step and invariant, a verdict line and a RESULT_JSON line.
# Parameters (environment): WW_STEPS (a step list, e.g. "send:3 mint:1000 burn:50 conflict*3"; else the topology's
# workload.steps; else the preset WW_PRESET: full (default) | aa (sequential, no concurrency) | posctl | conflict),
# WW_CONTROL=positive (the burn step also asserts the burned amount is still held, which must FAIL; the posctl
# preset sets it), WW_CONFIRM_S, WW_CLEAR_S, WW_SYNC_S, WW_AGREE_S, WW_FUND_BOXES, WW_FUND_NANOERG, WW_FEE.
# shellcheck source=rig/lib/wallet_workload.sh
source "$(dirname "$(readlink -f "$HOOK")")/../lib/wallet_workload.sh"
ww_steps="${WW_STEPS:-$(jq -r '.workload.steps // ""' "$CFG")}"
if [[ -z "$ww_steps" ]]; then
  ww_steps=$(ww_preset_steps "${WW_PRESET:-full}") || { echo "[wallet-workload] INCONCLUSIVE: unknown WW_PRESET '${WW_PRESET:-}' (full | aa | posctl | conflict)"; rig_verdict=INCONCLUSIVE; return 0; }
  [[ "${WW_PRESET:-full}" == posctl ]] && WW_CONTROL=positive
fi
if ww_expand "$ww_steps" | grep -q '^BAD:'; then echo "[wallet-workload] INCONCLUSIVE: bad step list '$ww_steps'"; rig_verdict=INCONCLUSIVE; return 0; fi
ww_run "$ww_steps"
echo "WALLET-WORKLOAD-DONE"
