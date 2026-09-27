#!/usr/bin/env bash
# stack.sh: combine the stacked patches of one upstream repo (status in patches.json's stack_statuses) into one diff
# against its base; for the ergo folders (ergo, ergo-matrix), optionally build the reference jar from it.
#
#   bash patches/stack.sh [--build] [--for <scenario>] [<dir>] [<base tag>]      (from the peeryard root; <dir> default: ergo)
#
# The clone is named by patches.json's clone_env. The patches are applied in id order to a scratch worktree of the
# base and one combined diff is written to $TMPDIR; its path is printed (sha256 on stderr). With --build (ergo
# folders), diffrun/build.sh builds base + that diff, cached by the diff's sha256, and prints the jar path. For the
# Rust nodes, apply the combined diff to a checkout of the base and build as patches.json's "build" says.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
build=""; [[ "${1:-}" == --build ]] && { build=1; shift; }
# --for <scenario>: also stack the patches whose only_for names that scenario (a temporary, per-scenario exception;
# the goal is one stack for every test). Without it, patches that carry only_for are left out.
for_sc=""; [[ "${1:-}" == --for ]] && { for_sc="${2:?--for needs a scenario name}"; shift 2; }
PD="${PEERYARD_PATCHES_DIR:-patches}"
d="${1:-ergo}"; J="$PD/$d/patches.json"; [[ -f "$J" ]] || { echo "no $J"; exit 2; }
cv=$(jq -r .clone_env "$J"); clone="${!cv:-}"; [[ -n "$clone" && -d "$clone" ]] || { echo "set $cv to a clone of $(jq -r .repo "$J")"; exit 2; }
[[ -z "$build" || "$(jq -r .build "$J")" == diffrun/build.sh ]] || { echo "--build is for the ergo folders only; for $d: $(jq -r .build "$J")"; exit 2; }
base="${2:-$(jq -r .base "$J")}"
# PEERYARD_PATCHES_EXTRA: a second patches directory with the same layout (<dir>/patches.json and files), whose entries
# are stacked after this tree's own. It lets a checkout carry patches that are not part of this repository (a private
# fix under disclosure, a local experiment) without editing the tree. Each patch is resolved to its own directory.
MJ="$(mktemp)"; trap 'rm -f "$MJ"' EXIT
jq --arg pd "$(realpath "$PD/$d")" '.patches |= map(. + {path: ($pd + "/" + .file)})' "$J" > "$MJ"
if [[ -n "${PEERYARD_PATCHES_EXTRA:-}" && -f "$PEERYARD_PATCHES_EXTRA/$d/patches.json" ]]; then
  jq -s --arg xd "$(realpath "$PEERYARD_PATCHES_EXTRA/$d")" '.[0] as $b | .[1] as $x | $b | .patches += ($x.patches | map(. + {path: ($xd + "/" + .file)}))' "$MJ" "$PEERYARD_PATCHES_EXTRA/$d/patches.json" > "$MJ.2" && mv "$MJ.2" "$MJ"
fi
SEL='.stack_statuses as $s | .patches | sort_by(.id)[] | select(.status as $x | $s | index($x)) | select((.only_for // null) == null or ((.only_for | index($for)) != null))'
mapfile -t files < <(jq -r --arg for "$for_sc" "$SEL | .path" "$MJ")
mapfile -t names < <(jq -r --arg for "$for_sc" "$SEL | .file" "$MJ")
if ((${#files[@]} == 0)); then echo "stack: empty" >&2; if [[ -n "$build" ]]; then DIFFRUN_ERGO_CLONE="$clone" bash diffrun/build.sh "$base"; fi; exit 0; fi
W="$(mktemp -d)"; trap 'git -C "$clone" worktree remove --force "$W/wt" >/dev/null 2>&1; rm -rf "$W" "$MJ"' EXIT
git -C "$clone" worktree add -q --detach "$W/wt" "$base"
for f in "${files[@]}"; do git -C "$W/wt" apply --index "$f" || { echo "stack: $(basename "$f") does not apply on $base (run patches/check.sh $d $base)" >&2; exit 1; }; done
out="${TMPDIR:-/tmp}/peeryard-stack-$d-$base${for_sc:+-for-$for_sc}.patch"; git -C "$W/wt" diff --cached > "$out"
echo "stack: ${names[*]} on $base -> $out sha256 $(sha256sum "$out" | cut -c1-16)" >&2
if [[ -z "$build" ]]; then echo "$out"; exit 0; fi
jar="$(DIFFRUN_ERGO_CLONE="$clone" bash diffrun/build.sh "$base" "$out")"
# name the stack beside the jar, once (a cache entry is never rewritten), for review/provenance.sh
[[ -f "$jar.stack.json" ]] || jq --arg b "$base" --arg c "$(sha256sum "$out" | cut -d' ' -f1)" --arg for "$for_sc" \
  "{repo, base: \$b, combined_sha256: \$c, for: (if \$for == \"\" then null else \$for end), patches: [$SEL | {id, file, upstream_pr, status, only_for}]}" "$MJ" > "$jar.stack.json"
echo "$jar"
