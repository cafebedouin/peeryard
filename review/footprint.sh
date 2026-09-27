#!/usr/bin/env bash
# footprint.sh <clone> <base> <pr> [--rows]: the pull request's production diff (diffrun/build.sh --dry-run over
# the production source dirs) grouped by the FIT rows of diffrun/scenarios/FIT.md, and the recipes that fit.
# --rows prints only the matched row ids (for pick.sh). The pull head must be fetched as pr-<N> (pick.sh does).
set -uo pipefail
CLONE="$1"; BASE="$2"; PR="$3"; ROWS="${4:-}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# build.sh's stderr is kept: when the dry run fails (no clone, a missing ref), that is the error, and an empty
# diff must not read as "no production files changed". Exit 3 then, with build.sh's message.
ERRF="$(mktemp)"; trap 'rm -f "$ERRF"' EXIT
if ! diff_out="$(DIFFRUN_ERGO_CLONE="$CLONE" bash "$HERE/../diffrun/build.sh" --dry-run "$BASE" "$BASE...pr-$PR" 2>"$ERRF")"; then
  echo "footprint: build.sh --dry-run failed for #$PR on $BASE:" >&2; cat "$ERRF" >&2; exit 3
fi
files="$(grep -oE '^diff --git a/\S+' <<< "$diff_out" | awk '{print $3}' | sed 's|^a/||')"
files="$(grep -vE '(^|/)src/(test|it|it2)/' <<< "$files")"   # tests are not production files for the fit question
nonsrc="$(grep -vE '\.(scala|java|sbt|conf|proto)$' <<< "$files" | grep -v '^$')"; files="$(grep -E '\.(scala|java|sbt|conf|proto)$' <<< "$files")"
[[ -n "$nonsrc" && -z "$ROWS" ]] && echo "not counted (not source): $(wc -l <<< "$nonsrc") file(s): $(head -3 <<< "$nonsrc" | tr '\n' ' ')"
[[ -n "$files" ]] || { [[ -n "$ROWS" ]] || echo "no production files changed (or the pull head pr-$PR is not fetched)"; exit 0; }
declare -A HIT
while read -r f; do
  case "$f" in
    *network/*|*scorex/core/network*) HIT[network]=1 ;;
    *modifierprocessors/*|*nodeView/history/*) HIT[history]=1 ;;
    *Snapshot*|*DigestState*) HIT[bootstrap]=1 ;;
    *nodeView/state/*) HIT[state]=1 ;;
    *mining/*|*settings/*) HIT[mining]=1 ;;
    *mempool/*|*wallet/*) HIT[mempool-wallet]=1 ;;
    *http/api/*) HIT[api]=1 ;;
    *) HIT[other]=1 ;;
  esac
done <<< "$files"
if [[ -n "$ROWS" ]]; then for k in network history state bootstrap mining mempool-wallet; do [[ -n "${HIT[$k]:-}" ]] && echo "$k"; done; exit 0; fi
echo "production files changed by #$PR on $BASE: $(wc -l <<< "$files")"; while read -r f; do echo "  $f"; done <<< "$files"
echo; echo "recipes that fit (diffrun/scenarios/FIT.md):"
[[ -n "${HIT[network]:-}" ]] && echo "  network       -> scenario:fork-convergence (or its smoke), interop"
[[ -n "${HIT[history]:-}" ]] && echo "  history       -> scenario:sibling-fork (or its smoke), scenario:fork-convergence"
[[ -n "${HIT[state]:-}" ]]   && echo "  state         -> scenario:fork-convergence (a switch is a rollback), interop"
[[ -n "${HIT[bootstrap]:-}" ]] && echo "  snapshot/digest -> bootstrap-modes (one pair; there is no smoke manifest, the scenario is one pair already)"
[[ -n "${HIT[mining]:-}" ]]  && echo "  mining/params -> interop (no review kind covers the retarget; the rig example soak measures block rate across it, run by hand: rig/run-suite.sh soak)"
[[ -n "${HIT[mempool-wallet]:-}" ]] && echo "  mempool/wallet -> txload"
[[ -n "${HIT[api]:-}" ]]     && echo "  api           -> none (the scenarios poll /info and /blocks/at; a change there can VOID runs)"
[[ -n "${HIT[other]:-}" ]]   && echo "  other         -> read-review; hunk-isolation if mixed with the rows above"
exit 0   # the last [[ ]] && … line returns 1 when its row is absent; the listing itself succeeded
