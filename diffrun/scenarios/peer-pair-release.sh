#!/usr/bin/env bash
# peer-pair-release: this role's jar (node A, mining) and a published ergoplatform/ergo release jar (node B, dials A)
# on one two-node network, bring-up gate off; the release jar is fetched by tag and checked against a pinned sha256.
# Before the network starts, a payload check: this role's jar writes its sync-info payloads (lib/sync-payload/Emit.java:
# V2 always, V3 if the jar has ErgoSyncInfoV3) and the release jar parses them (Parse.java). Then the peer-pair
# question: after PP_WAIT_S seconds, is each node connected to the other, and did either fail to parse the other's
# messages or blacklist it? Metric `paired` as in peer-pair. The release node's version is reported under "release",
# not "versions" (diffrun checks every "versions" entry against this role's jar).
# Env: PP_RELEASE_TAG (vN.N.N), PP_RELEASE_SHA256 (64 hex, required: releases do not all publish a checksum),
# PP_WAIT_S. The release node gets ergo.node.rejectStorageRentTxs=false (the 6.1 line requires the key; older
# nodes ignore it). Node A is always this role's jar: it starts the rig's genesis probe.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=diffrun/scenarios/lib/rig-scenario.sh
source "$here/lib/rig-scenario.sh"
tag="${PP_RELEASE_TAG:-}"; sha="${PP_RELEASE_SHA256:-}"
[[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "INCONCLUSIVE: PP_RELEASE_TAG must be vN.N.N, got '$tag'"; exit 3; }
[[ "$sha" =~ ^[0-9a-f]{64}$ ]] || { echo "INCONCLUSIVE: PP_RELEASE_SHA256 must pin the release jar (64 hex)"; exit 3; }
jar="$(readlink -f "$1")"; [[ -f "$jar" ]] || { echo "INCONCLUSIVE: no jar: $1"; exit 3; }
WORKDIR="${WORKDIR:-$(mktemp -d)}"; mkdir -p "$WORKDIR"; export WORKDIR
rel="$WORKDIR/ergo-${tag#v}.jar"
curl -fsSL --retry 3 -o "$rel" "https://github.com/ergoplatform/ergo/releases/download/$tag/ergo-${tag#v}.jar" \
  || { echo "INCONCLUSIVE: could not download ergo-${tag#v}.jar of $tag"; exit 3; }
got="$(sha256sum "$rel" | cut -d' ' -f1)"
[[ "$got" == "$sha" ]] || { echo "INCONCLUSIVE: release jar sha256 $got, pinned $sha"; exit 3; }
echo "[peer-pair-release] release $tag jar sha256 $got"
pc="$WORKDIR/payload"; mkdir -p "$pc"; jv="${PEERYARD_JAVA:-java}"
emit="$(cd "$pc" && "$jv" -cp "$jar" "$here/lib/sync-payload/Emit.java" "$pc" 2>&1 | grep -E '^v[23] ')"
while IFS= read -r l; do echo "[payload] this jar writes $l"; done <<< "$emit"
files=(); for v in v2 v3; do [[ -f "$pc/$v.hex" ]] && files+=("$v.hex"); done
parse="$(cd "$pc" && "$jv" -cp "$rel" "$here/lib/sync-payload/Parse.java" "${files[@]}" 2>&1 | grep -E '^v[23]\.hex: ')"
while IFS= read -r l; do echo "[payload] $tag parses $l"; done <<< "$parse"
PP_V2_HEX="$(cat "$pc/v2.hex" 2>/dev/null)"; PP_V3_HEX="$(cat "$pc/v3.hex" 2>/dev/null || echo absent)"
PP_V2_PARSE="$(sed -n 's/^v2\.hex: \([A-Za-z]*\).*/\1/p' <<< "$parse")"; PP_V3_PARSE="$(sed -n 's/^v3\.hex: \([A-Za-z]*\).*/\1/p' <<< "$parse")"
PP_V3_REASON="$(sed -n 's/^v3\.hex: Failure \([^@]*\).*/\1/p' <<< "$parse" | head -c 120)"
export PP_RELEASE_JAR="$rel" PP_RELEASE_TAG="$tag" PP_RELEASE_SHA="$got" PP_V2_HEX PP_V3_HEX PP_V2_PARSE PP_V3_PARSE PP_V3_REASON
run_rig_scenario "$here/hooks/peer-pair-release.json" "$here/hooks/peer-pair-release.sh" "$jar"
