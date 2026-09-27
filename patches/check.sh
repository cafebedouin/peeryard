#!/usr/bin/env bash
# check.sh: for every patch peeryard carries for one upstream repo, report whether it is still needed against that
# repo's newest release, so a release never collides with a patch peeryard still carries.
#
#   bash patches/check.sh [<dir>] [<release tag>]      (from the peeryard root; <dir> default: ergo)
#
# <dir> is a folder under patches/ (ergo, ergo-matrix, ergo-node-rust, arkadianet) holding patches.json and the .patch files.
# The clone of that repo is named by the variable in patches.json's clone_env (e.g. DIFFRUN_ERGO_CLONE); tags are
# fetched from https://github.com/<repo>. The tag defaults to the repo's newest non-prerelease release; a folder whose
# patches.json names a "branch" (ergo-matrix: weak-blocks) is checked against that branch's current head instead.
# Patches are checked in id order, each on top of the stacked patches before it (a stacked patch may build on an
# earlier one):
#   NEEDED     it applies: keep it (a stacked one is then applied for the next checks)
#   CONTAINED  it reverse-applies: it has landed in the release; remove it from the stack
#   COLLIDES   neither: the release changed those lines; rebase or re-derive it
# plus the upstream PR's state. Exit 0 when every stacked patch is NEEDED, 1 when any is not, 2 on a usage error.
# Env (for tests): PEERYARD_PATCHES_DIR (default patches), PEERYARD_OFFLINE=1 (no tag fetch, no PR lookup; the tag
# must be given and present in the clone).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
PD="${PEERYARD_PATCHES_DIR:-patches}"; OFF="${PEERYARD_OFFLINE:-0}"
d="${1:-ergo}"; J="$PD/$d/patches.json"; [[ -f "$J" ]] || { echo "no $J"; exit 2; }
need=(git jq); [[ "$OFF" == 1 ]] || need+=(gh)   # gh is used online only (latest release, PR state)
for c in "${need[@]}"; do command -v "$c" >/dev/null || { echo "missing: $c"; exit 2; }; done
repo=$(jq -r .repo "$J"); cv=$(jq -r .clone_env "$J"); clone="${!cv:-}"
[[ -n "$clone" && -d "$clone" ]] || { echo "set $cv to a clone of $repo"; exit 2; }
branch=$(jq -r '.branch // empty' "$J")
[[ "$OFF" == 1 ]] || git -C "$clone" fetch -q --tags "https://github.com/$repo"
[[ "$OFF" == 1 || -z "$branch" ]] || git -C "$clone" fetch -q "https://github.com/$repo" "+refs/heads/$branch:refs/remotes/peeryard/$branch"
[[ "$OFF" == 1 && -z "${2:-}" ]] && { echo "offline: give the tag"; exit 2; }
if [[ -n "${2:-}" ]]; then tag="$2"; elif [[ -n "$branch" ]]; then tag="peeryard/$branch"
else tag="$(gh release view -R "$repo" --json tagName --jq .tagName)"; fi
git -C "$clone" rev-parse -q --verify "refs/tags/$tag^{commit}" >/dev/null || git -C "$clone" rev-parse -q --verify "$tag^{commit}" >/dev/null \
  || { echo "tag $tag not found in $clone"; exit 2; }
W="$(mktemp -d)"; trap 'git -C "$clone" worktree remove --force "$W/wt" >/dev/null 2>&1; rm -rf "$W" "$MJ"' EXIT
git -C "$clone" worktree add -q --detach "$W/wt" "$tag"
if [[ -n "$branch" && -z "${2:-}" ]]; then echo "$repo branch $branch at $(git -C "$W/wt" rev-parse --short=12 HEAD) (patches based on $(jq -r .base "$J"))"
else echo "$repo release $tag (patches based on $(jq -r .base "$J"))"; fi
printf '%-4s %-18s %-10s %-14s %s\n' id status verdict "upstream PR" title
# PEERYARD_PATCHES_EXTRA: a second patches directory with the same layout (<dir>/patches.json and files), whose entries
# are stacked after this tree's own. It lets a checkout carry patches that are not part of this repository (a private
# fix under disclosure, a local experiment) without editing the tree. Each patch is resolved to its own directory.
MJ="$(mktemp)"; trap 'rm -f "$MJ"' EXIT
jq --arg pd "$(realpath "$PD/$d")" '.patches |= map(. + {path: ($pd + "/" + .file)})' "$J" > "$MJ"
if [[ -n "${PEERYARD_PATCHES_EXTRA:-}" && -f "$PEERYARD_PATCHES_EXTRA/$d/patches.json" ]]; then
  jq -s --arg xd "$(realpath "$PEERYARD_PATCHES_EXTRA/$d")" '.[0] as $b | .[1] as $x | $b | .patches += ($x.patches | map(. + {path: ($xd + "/" + .file)}))' "$MJ" "$PEERYARD_PATCHES_EXTRA/$d/patches.json" > "$MJ.2" && mv "$MJ.2" "$MJ"
fi
bad=0; stack=" $(jq -r '.stack_statuses | join(" ")' "$J") "
while IFS=$'\t' read -r id file status pr title; do
  f="$file"
  if git -C "$W/wt" apply --check "$f" 2>/dev/null; then v=NEEDED
  elif git -C "$W/wt" apply --reverse --check "$f" 2>/dev/null; then v=CONTAINED
  else v=COLLIDES; fi
  prs="-"; [[ "$pr" != null && "$OFF" != 1 ]] && prs="#$pr $(gh pr view "$pr" -R "$repo" --json state --jq .state 2>/dev/null | tr '[:upper:]' '[:lower:]')"
  printf '%-4s %-18s %-10s %-14s %s\n' "$id" "$status" "$v" "$prs" "$title"
  if [[ "$stack" == *" $status "* ]]; then
    if [[ $v == NEEDED ]]; then git -C "$W/wt" apply "$f"; else bad=1; fi
  fi
done < <(jq -r '.patches | sort_by(.id)[] | [.id, .path, .status, (.upstream_pr|tostring), .title] | @tsv' "$MJ")
exit $bad
