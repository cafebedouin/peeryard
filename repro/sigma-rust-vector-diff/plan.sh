#!/usr/bin/env bash
# plan.sh "<change> ..."  — turn the change list into the build matrix.
# A change is `pr:<N>` (merge refs/pull/<N>/head of ergoplatform/sigma-rust onto the base), `pick:<40-hex sha>`
# (cherry-pick that commit onto the base), `merge:<owner>/<repo>@<40-hex sha>` (fetch that commit from that GitHub
# repository, e.g. a fork holding several changes together, and merge it onto the base) or `noop` (the base again: a
# control). The base itself is always the first
# label. Prints three lines for $GITHUB_OUTPUT:
#   matrix=[{"label":"base","change":"base"},{"label":"pr884","change":"pr:884"},...]
#   labels=base pr884 ...
#   controls=noop          (the labels that must show no fixed and no regressed entry)
set -euo pipefail
max=12
labels=(base); changes=(base); controls=()
read -r -a toks <<< "${1:-}"
for t in "${toks[@]}"; do
  case "$t" in
    pr:*)   n="${t#pr:}"; [[ "$n" =~ ^[1-9][0-9]{0,6}$ ]] || { echo "plan: bad PR number in '$t'" >&2; exit 1; }; l="pr$n" ;;
    pick:*) s="${t#pick:}"; [[ "$s" =~ ^[0-9a-f]{40}$ ]] || { echo "plan: '$t' needs a 40-hex commit" >&2; exit 1; }; l="pick-${s:0:12}" ;;
    merge:*) r="${t#merge:}"; [[ "$r" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+@[0-9a-f]{40}$ ]] || { echo "plan: '$t' needs <owner>/<repo>@<40-hex commit>" >&2; exit 1; }; l="merge-${r##*@}"; l="${l:0:18}" ;;
    noop)   l=noop; controls+=(noop) ;;
    *)      echo "plan: unknown change '$t' (want pr:<N>, pick:<sha>, merge:<owner>/<repo>@<sha> or noop)" >&2; exit 1 ;;
  esac
  for x in "${labels[@]}"; do [[ "$x" != "$l" ]] || { echo "plan: '$t' is listed twice" >&2; exit 1; }; done
  labels+=("$l"); changes+=("$t")
done
(( ${#labels[@]} - 1 <= max )) || { echo "plan: at most $max changes per run" >&2; exit 1; }
m=""
for i in "${!labels[@]}"; do m+="${m:+,}{\"label\":\"${labels[$i]}\",\"change\":\"${changes[$i]}\"}"; done
echo "matrix=[$m]"
echo "labels=${labels[*]}"
echo "controls=${controls[*]}"
