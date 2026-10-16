#!/usr/bin/env bash
# devnet-miner.sh <ergo.jar> [DevnetMiner args...]: compile rig/lib/devnet-miner/DevnetMiner.java against the node jar
# (once per jar, cached under ~/.peeryard/devnet-miner/) and run it. See the Java file for what it is for.
set -euo pipefail
jar="$(readlink -f "${1:?node jar}")"; shift; here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
out="${PEERYARD_MINER_DIR:-$HOME/.peeryard/devnet-miner}/$(sha256sum "$jar" | cut -c1-16)"
if [[ ! -f "$out/DevnetMiner.class" ]]; then mkdir -p "$out"; javac -cp "$jar" -d "$out" "$here/devnet-miner/DevnetMiner.java"; fi
exec java -cp "$out:$jar" DevnetMiner "$@"
