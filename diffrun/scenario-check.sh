#!/usr/bin/env bash
# scenario-check.sh: a scenario's own dispatch-time check of its effective env, before anything is built or run.
#
#   [DIFFRUN_LINE=<line>] bash diffrun/scenario-check.sh <manifest.json>
#
# A scenario whose env names something that must exist (rig-example's RIG_EXAMPLE: a rig example) may ship a check
# beside its script: diffrun/scenarios/<script without .sh>.check.sh. This runs it with the manifest's env (after
# scenario-env.sh wrote any overrides into it) in its environment, plus DIFFRUN_LINE when the caller sets it, and exits
# with its status; a scenario with no check passes (exit 0). pr-scenario.yml calls it in its inputs step, so a wrong
# name fails the dispatch in seconds instead of after the build, with every run INCONCLUSIVE.
set -euo pipefail
m="${1:?manifest}"; HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "$m" ]] || { echo "scenario-check: no manifest $m"; exit 1; }
s="$(jq -r '.script // empty' "$m")"; [[ "$s" == *.sh ]] || exit 0
c="$HERE/scenarios/${s%.sh}.check.sh"; [[ -f "$c" ]] || exit 0
kv=(); while IFS= read -r l; do kv+=("$l"); done < <(jq -r '(.env // {}) | to_entries[] | "\(.key)=\(.value)"' "$m")
env ${kv[@]+"${kv[@]}"} bash "$c"
