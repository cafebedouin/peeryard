#!/usr/bin/env bash
# register.sh: write a sidecar <jar>.json for a pre-built jar (a release, or a jar built elsewhere).
#
#   bash diffrun/register.sh [-f] [--override-version] <jar> [<expected-appVersion>]
#
# When <jar> resolves (through symlinks) to a jar that already has a diffrun/build.sh sidecar, the version defaults
# to that sidecar's expected_app_version, and a different version is refused unless --override-version is given
# (-f only replaces an existing sidecar): a hand-typed version that disagrees with the build VOIDs every run.
#
# The sidecar records only the jar's sha256 and the appVersion its nodes are expected to report. It is a claim,
# and run.sh checks it: every run's reported versions must equal it, so a wrong registration VOIDs that jar's runs.
# An existing sidecar with different content is not overwritten without -f. The sidecar sits next to the path
# given (a symlink gets its own sidecar), so one jar can be registered under several paths.
set -euo pipefail
FORCE=0; OVR=0
while [[ "${1:-}" == -f || "${1:-}" == --override-version ]]; do if [[ "$1" == -f ]]; then FORCE=1; else OVR=1; fi; shift; done
[[ $# == 1 || ( $# == 2 && -n "$2" ) ]] || { echo "usage: $0 [-f] [--override-version] <jar> [<expected-appVersion>]" >&2; exit 2; }
JAR="$1"; VER="${2:-}"
[[ -f "$JAR" ]] || { echo "register: no jar: $JAR" >&2; exit 2; }
TGT="$(readlink -f "$JAR")"; BUILT=""
[[ "$TGT" != "$(realpath -s "$JAR")" && -f "$TGT.json" ]] && BUILT="$(jq -r '.expected_app_version // empty' "$TGT.json")"
if [[ -z "$VER" ]]; then
  [[ -n "$BUILT" ]] || { echo "register: no version given and $JAR does not resolve to a jar with a sidecar" >&2; exit 2; }
  VER="$BUILT"
elif [[ -n "$BUILT" && "$VER" != "$BUILT" && $OVR == 0 ]]; then
  echo "register: $TGT.json says the build reports $BUILT, not $VER (--override-version registers $VER anyway)" >&2; exit 2
fi
NEW="$(jq -n --arg sha "$(sha256sum "$JAR" | cut -d' ' -f1)" --arg ver "$VER" \
  '{sidecar_schema_version: 1, kind: "registered", jar_sha256: $sha, expected_app_version: $ver}')"
if [[ -e "$JAR.json" && $FORCE == 0 ]] && ! diff -q <(jq -S . "$JAR.json") <(jq -S . <<< "$NEW") >/dev/null; then
  echo "register: $JAR.json exists with different content (use -f to replace):" >&2
  diff <(jq -S . "$JAR.json") <(jq -S . <<< "$NEW") >&2 || true; exit 2
fi
printf '%s\n' "$NEW" > "$JAR.json"
echo "register: $JAR.json -> $VER" >&2
