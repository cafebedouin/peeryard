#!/usr/bin/env bash
# node-release.sh: keep the rig on the current Ergo reference node, and know which local patches still apply.
#
#   rig/node-release.sh latest            the newest stable release tag on GitHub (pre-releases skipped), and what is cached
#   rig/node-release.sh fetch [tag]       download that release's jar into ~/.peeryard/jars/ (sha256 recorded), and point
#                                         ~/.peeryard/jars/default.jar at it; rig.sh uses default.jar when no jar is given
#   rig/node-release.sh jar               print the path of default.jar (for PEERYARD_JAR=$(rig/node-release.sh jar))
#   rig/node-release.sh patches [tag]     for every entry in rig/patches/manifest.json: whether it still applies at that
#                                         release (by version range) and whether its upstream PR or issue has closed
#   rig/node-release.sh check             exit 1 when a newer stable release exists than default.jar: for a cron or CI
#
# A "patch" here is anything the rig has to do differently because of the node version: a config key that must be set,
# a rule a devnet cannot activate, a behaviour worked around in a hook. Each manifest entry says where it applies and
# which upstream PR or issue would clear it; `patches` reports which have cleared, so they can be removed when the
# release that carries the fix becomes the default. Needs gh (authenticated) and jq.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; JARS="${PEERYARD_JARS:-$HOME/.peeryard/jars}"; mkdir -p "$JARS"
REPO=ergoplatform/ergo; MANIFEST="$HERE/patches/manifest.json"
latest_tag(){ gh release list -R "$REPO" --limit 20 --json tagName,isPrerelease --jq '[.[] | select(.isPrerelease | not)][0].tagName'; }
default_tag(){ [[ -L "$JARS/default.jar" ]] && basename "$(readlink "$JARS/default.jar")" .jar | sed 's/^ergo-/v/' || echo ""; }
vernum(){ echo "${1#v}" | awk -F. '{printf "%d%03d%03d\n", $1, $2, $3}'; }
case "${1:-}" in
  latest) t="$(latest_tag)"; echo "latest stable: $t"; d="$(default_tag)"; echo "rig default:   ${d:-none} ($JARS/default.jar)"; ls "$JARS" 2>/dev/null | grep -E '^ergo-.*\.jar$' | sed 's/^/cached:        /' ;;
  fetch) t="${2:-$(latest_tag)}"; jar="ergo-${t#v}.jar"
    if [[ ! -f "$JARS/$jar" ]]; then gh release download "$t" -R "$REPO" -p "$jar" -D "$JARS"; fi
    sha="$(sha256sum "$JARS/$jar" | cut -c1-64)"; echo "$sha  $jar  $(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$JARS/SHA256SUMS"
    ln -sfn "$JARS/$jar" "$JARS/default.jar"; echo "default.jar -> $jar (sha256 $sha)" ;;
  jar) [[ -L "$JARS/default.jar" ]] && readlink "$JARS/default.jar" || { echo "no default jar: run rig/node-release.sh fetch" >&2; exit 1; } ;;
  check) t="$(latest_tag)"; d="$(default_tag)"
    if [[ -z "$d" ]]; then echo "no default jar; latest stable is $t"; exit 1; fi
    if [[ "$(vernum "$t")" -gt "$(vernum "$d")" ]]; then echo "newer release: $t (default is $d); run rig/node-release.sh fetch $t, then rig/node-release.sh patches $t"; exit 1; fi
    echo "default $d is the latest stable" ;;
  patches) t="${2:-$(default_tag)}"; [[ -n "$t" ]] || { echo "no tag and no default jar" >&2; exit 2; }; v="$(vernum "$t")"
    jq -c '.[]' "$MANIFEST" | while read -r e; do
      id=$(jq -r .id <<<"$e"); from=$(jq -r .applies_from <<<"$e"); until=$(jq -r '.applies_until // empty' <<<"$e"); up=$(jq -r '.upstream // empty' <<<"$e")
      applies=yes; [[ "$(vernum "$from")" -gt "$v" ]] && applies=no; [[ -n "$until" && "$(vernum "$until")" -le "$v" ]] && applies=no
      state=""; if [[ "$up" =~ ^(pr|issue)/([0-9]+)$ ]]; then
        if [[ "${BASH_REMATCH[1]}" == pr ]]; then state="$(gh pr view "${BASH_REMATCH[2]}" -R "$REPO" --json state,mergedAt --jq '.state + (if .mergedAt then " " + .mergedAt[:10] else "" end)' 2>/dev/null || echo unknown)"
        else state="$(gh issue view "${BASH_REMATCH[2]}" -R "$REPO" --json state,closedAt --jq '.state + (if .closedAt then " " + .closedAt[:10] else "" end)' 2>/dev/null || echo unknown)"; fi; fi
      printf '%-34s applies at %s: %-3s  upstream: %s %s\n' "$id" "$t" "$applies" "${up:-none}" "$state"
      [[ -n "$up" && "$state" == MERGED* || "$state" == CLOSED* ]] && echo "    -> cleared upstream; check whether $t carries it and retire the entry" || true
    done ;;
  *) sed -n '2,16p' "${BASH_SOURCE[0]}"; exit 2 ;;
esac
