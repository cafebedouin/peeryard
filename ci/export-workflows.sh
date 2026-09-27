#!/usr/bin/env bash
# export-workflows.sh: the GitHub workflows for a peeryard repository, written from the copies that run in the
# repository peeryard is developed in (where the tree sits under `peeryard/`). The exported files address the tree as the
# repository root, so a clone or fork of peeryard runs them as they are: `.github/workflows/sweep.yml` (every rig example
# and one diffrun pair per scenario on the reference nodes, by hand or on a push to `ci/sweep`) and `aa.yml` (an A/A
# calibration of the two headline scenarios on the release jar). They are the runs a published verdict rests on: GitHub-
# hosted `ubuntu-24.04` runners, one runner class anyone can re-run.
#
#   bash ci/export-workflows.sh [--check]     # from the peeryard root; --check: exit 1 if the exported files are stale
#
# Source: ../.github/workflows/peeryard-{sweep,aa}.yml when that directory exists (development layout); otherwise the
# exported files are the source of truth and there is nothing to do.
set -euo pipefail
cd "$(dirname "$0")/.."
SRC=../.github/workflows; OUT=.github/workflows
[[ -d "$SRC" ]] || { echo "export-workflows: no $SRC beside this tree: the files under $OUT are the source"; exit 0; }
check=0; [[ "${1:-}" == --check ]] && check=1
mkdir -p "$OUT"; rc=0
for w in sweep aa; do
  in="$SRC/peeryard-$w.yml"; out="$OUT/$w.yml"; [[ -f "$in" ]] || { echo "export-workflows: missing $in" >&2; exit 2; }
  tmp="$(mktemp)"
  { echo "# Exported by ci/export-workflows.sh (same steps, paths from this repository's root); if this repository is the"
    echo "# source, edit here."
    sed -E -e 's#cd peeryard && ##g' -e 's#; cd peeryard$##' -e "s#'peeryard/#'#g" -e 's#peeryard/##g' \
           -e "s#ci/peeryard-$w#ci/$w#g" -e '/PEERYARD_PATCHES_EXTRA/d' "$in"; } > "$tmp"
  if grep -qE "peeryard/|cd peeryard" "$tmp"; then echo "export-workflows: a peeryard/ path survived in $out:" >&2; grep -nE "peeryard/|cd peeryard" "$tmp" >&2; exit 2; fi
  if (( check )); then
    if [[ -f "$out" ]] && cmp -s "$tmp" "$out"; then echo "export-workflows: $out up to date"; else echo "export-workflows: $out is STALE (run ci/export-workflows.sh)"; rc=1; fi
  else cp "$tmp" "$out"; echo "export-workflows: wrote $out"; fi
  rm -f "$tmp"
done
exit $rc
