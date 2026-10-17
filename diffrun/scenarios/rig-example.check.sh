#!/usr/bin/env bash
# rig-example.check.sh: the dispatch-time check of the rig-example scenario's env (diffrun/scenario-check.sh runs it
# with the manifest's effective env, before anything is built). Exits 0 when RIG_EXAMPLE resolves (a suite.tsv example
# whose nodes all run one role's jar) and RIG_EXAMPLE_ENV overrides only keys its row declares; 1 with the reason
# otherwise. DIFFRUN_LINE (pr-scenario's line input, when set): a Matrix example needs line=matrix or matrix-stack.
#
#   RIG_EXAMPLE=<name> [RIG_EXAMPLE_ENV='KEY:VALUE ...'] [DIFFRUN_LINE=<line>] bash diffrun/scenarios/rig-example.check.sh
#   bash diffrun/scenarios/rig-example.check.sh --list      every suite.tsv example: runnable, or refused and why
set -uo pipefail
# shellcheck source=diffrun/scenarios/lib/rig-scenario.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/rig-scenario.sh"
if [[ "${1:-}" == --list ]]; then rig_example_list; exit $?; fi
rig_example_resolve "${RIG_EXAMPLE:-}" "${RIG_EXAMPLE_ENV:-}" || { echo "rig-example: $RX_ERR"; exit 1; }
if [[ $RX_MATRIX == 1 && -n "${DIFFRUN_LINE:-}" && "$DIFFRUN_LINE" != matrix && "$DIFFRUN_LINE" != matrix-stack ]]; then
  echo "rig-example: '$RIG_EXAMPLE' runs on a Matrix (weak-blocks) jar: line=matrix or matrix-stack, not '$DIFFRUN_LINE'"; exit 1
fi
echo "rig-example: $RIG_EXAMPLE (marker '$RX_MARKER', timeout ${RX_TIMEOUT}s, env ${RX_ENV[*]:--})$([[ $RX_MATRIX == 1 ]] && echo ', Matrix line')$([[ $RX_EXPERIMENTAL == 1 ]] && echo ', experimental in the suite (a measured pass rate below 100% on some hosts)')"
