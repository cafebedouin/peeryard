#!/usr/bin/env bash
# provenance.sh: the peeryard version and the node builds a run used, as one clause for a credit line.
#
#   bash review/provenance.sh                       -> peeryard v0.1.0
#   bash review/provenance.sh <jar>                 -> peeryard v0.1.0 on <node>
#   bash review/provenance.sh <base jar> <cand jar> -> peeryard v0.1.0 on base <node> and candidate <node>
#
# <node> is "reference node <base>+<patch ids> (<jar sha256, 12 hex>)" for a jar built by patches/stack.sh --build
# (it leaves <jar>.stack.json beside the jar), "<app version> (<sha>)" for a jar with a diffrun/build.sh sidecar,
# and "<file name> (<sha>)" otherwise (a downloaded release jar). The version is the VERSION file; the commit is
# added when the tree is a git checkout. Paste the output after "using " in the credit line (review/templates/).
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
v="peeryard v$(tr -d '[:space:]' < "$here/VERSION")"
rev="$(git -C "$here" rev-parse --short HEAD 2>/dev/null || true)"; [[ -n "$rev" ]] && v="$v ($rev)"
node(){ local j="$1" sha; [[ -f "$j" ]] || { echo "no such jar: $j" >&2; exit 2; }
  sha="$(sha256sum "$j" | cut -c1-12)"
  if [[ -f "$j.stack.json" ]]; then echo "reference node $(jq -r '"\(.base)+\([.patches[].id] | join(","))"' "$j.stack.json") ($sha)"
  elif [[ -f "$j.json" ]]; then echo "$(jq -r '.expected_app_version // .source_ref[0:10]' "$j.json") ($sha)"
  else echo "$(basename "$j") ($sha)"; fi; }
case $# in
  0) echo "$v" ;;
  1) echo "$v on $(node "$1")" ;;
  2) echo "$v on base $(node "$1") and candidate $(node "$2")" ;;
  *) echo "usage: provenance.sh [<jar> | <base jar> <candidate jar>]" >&2; exit 2 ;;
esac
