# shellcheck shell=bash
# rig-example hook (sourced by rig/rig.sh for diffrun/scenarios/rig-example.sh): record every node's appVersion, then
# run the rig example's own hook (RIG_EXAMPLE_HOOK) unchanged, then record the versions again (a node launched later by
# the example, a "defer": true node, answers only then). HOOK is set to the example's hook first, so an example that
# finds its siblings through "$HOOK" (rig/lib/phases.sh, matrix-compat.sh, ...) finds them. The example's verdict
# (rig_verdict) and output are the rig's as under rig/run-suite.sh; the scenario reads the two version lines and the
# example's PASS marker from the rig's output.
_rx_versions(){ local n v o="{}"
  for n in "${NODES[@]}"; do
    v="$(rest "$n" /info 2>/dev/null | jq -r '.appVersion // empty' 2>/dev/null)"
    [[ -n "$v" ]] && o="$(jq -c --arg n "$n" --arg v "$v" '.[$n] = $v' <<< "$o")"
  done; echo "$o"; }
echo "[rig-example] versions at hand-off: $(_rx_versions)"
HOOK="$RIG_EXAMPLE_HOOK"
# shellcheck disable=SC1090
source "$HOOK"
echo "[rig-example] versions after the hook: $(_rx_versions)"
