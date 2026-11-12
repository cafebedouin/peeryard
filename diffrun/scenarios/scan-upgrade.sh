#!/usr/bin/env bash
# scan-upgrade: wallet scans written by a released node, read after an in-place upgrade to this role's jar
# (ergoplatform/ergo#1668: the scan id type). One node, no peers. The writer is the release named by
# SCANUP_WRITER_TAG (default v6.0.8), its jar checked against SCANUP_WRITER_SHA256. It registers scans and mines
# until they hold boxes; the node is then stopped and started on this role's jar over the same data directory, and
# every scan answer is compared with the writer's; see hooks/scan-upgrade.sh.
# SCANUP_WRAP=1 (manifest scan-upgrade-wrap) first registers scans until the release's scan counter passes 32767.
#   bash diffrun/scenarios/scan-upgrade.sh <jar>
# SCANUP_WRITER_JAR=<path> uses a local copy of the release jar (its sha256 is still checked).
set -uo pipefail
tag="${SCANUP_WRITER_TAG:-v6.0.8}"; want="${SCANUP_WRITER_SHA256:-e1269f3c9b1c75d29f1f1bded720101792db41118757016123de113668353346}"
jar="${SCANUP_WRITER_JAR:-}"
if [[ -z "$jar" ]]; then
  dir="${HOME}/.peeryard/jars"; mkdir -p "$dir"; jar="$dir/ergo-${tag#v}.jar"
  if [[ ! -f "$jar" ]]; then
    curl -sfL --retry 3 -o "$jar.part" "https://github.com/ergoplatform/ergo/releases/download/$tag/ergo-${tag#v}.jar" \
      && mv "$jar.part" "$jar" || { echo "INCONCLUSIVE: could not download the $tag release jar"; exit 3; }
  fi
fi
got="$(sha256sum "$jar" 2>/dev/null | cut -d' ' -f1)"
[[ "$got" == "$want" ]] || { echo "INCONCLUSIVE: writer jar $jar sha256 ${got:-none}, expected $want"; exit 3; }
echo "[scan-upgrade] writer $tag $(basename "$jar") sha256 ${got:0:16}"
SCANUP_WRITER_JAR="$(readlink -f "$jar")"; export SCANUP_WRITER_JAR SCANUP_WRITER_TAG="$tag"
# shellcheck source=diffrun/scenarios/lib/rig-scenario.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/rig-scenario.sh"
run_rig_scenario "$(dirname "${BASH_SOURCE[0]}")/hooks/scan-upgrade.json" "$(dirname "${BASH_SOURCE[0]}")/hooks/scan-upgrade.sh" "$1"
