#!/usr/bin/env bash
# scenario-env.sh: override keys of a manifest's env in place (pr-scenario.yml's scenario_env input; a CI checkout's
# copy of the manifest, so run.sh records the effective env in verdict.json's provenance).
#
#   bash diffrun/scenario-env.sh <manifest.json> '<KEY=VALUE>[;<KEY=VALUE>...]'
#
# Only keys the manifest's env already declares may be set (a scenario's parameters are the manifest's to name), and a
# value is [A-Za-z0-9._ :,-] only (it reaches the scenario through the environment, never eval'd; ':' and ',' let
# a step list such as 'send:3, mint' through, '*' and shell metacharacters stay out). An empty override
# string changes nothing. Prints one line per key set; exits 1, naming the offending item, on anything else.
set -euo pipefail
m="${1:?manifest}"; spec="${2:-}"
[[ -f "$m" ]] || { echo "scenario-env: no manifest $m"; exit 1; }
[[ -n "$spec" ]] || exit 0
IFS=';' read -ra items <<< "$spec"
for it in "${items[@]}"; do
  it="${it#"${it%%[![:space:]]*}"}"; it="${it%"${it##*[![:space:]]}"}"   # trim
  [[ -z "$it" ]] && continue
  [[ "$it" =~ ^([A-Z][A-Z0-9_]*)=([A-Za-z0-9.\ _:,-]+)$ ]] || { echo "scenario-env: '$it' is not KEY=VALUE with KEY [A-Z0-9_] and VALUE [A-Za-z0-9._ :,-]"; exit 1; }
  k="${BASH_REMATCH[1]}"; v="${BASH_REMATCH[2]}"
  jq -e --arg k "$k" '(.env // {}) | has($k)' "$m" >/dev/null || { echo "scenario-env: $k is not a key of $(basename "$m")'s env ($(jq -r '(.env // {}) | keys | join(", ")' "$m"))"; exit 1; }
  t="$(mktemp)"; jq --arg k "$k" --arg v "$v" '.env[$k] = $v' "$m" > "$t" && mv "$t" "$m"
  echo "scenario-env: $(basename "$m") env $k=$v"
done
