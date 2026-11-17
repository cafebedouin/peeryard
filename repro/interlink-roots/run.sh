#!/usr/bin/env bash
# Runs interlink_roots.py (beside this script; its header states the claim and what counts against it) against one
# public Ergo mainnet node: for every header of the NiPoPoW proof the node serves (m = 6, k = 10) and for the blocks
# around the latest voting-epoch start, is the Merkle root of the interlinks alone equal to the header's
# extensionHash? Claim: they differ at the first block of a voting epoch and at no other header examined.
# The last line is "VERDICT: as claimed" (exit 0), "VERDICT: NOT as claimed" (exit 1) or "VERDICT: inconclusive"
# (exit 2: the node did not answer, or no voting-epoch start was among the headers).
#
# Needs: python3 (standard library only) and network access to the node. A handful of small GET requests.
#   bash run.sh                      # NODE defaults to the public node below
#   NODE=http://127.0.0.1:9053 bash run.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NODE_SET="${NODE:-}"; NODE="${NODE:-http://213.239.193.208:9053}"
echo "node: $([[ -n "$NODE_SET" ]] && echo "$NODE" || echo "the default public node"); script sha256: $(sha256sum "$HERE/interlink_roots.py" | cut -c1-64)"
python3 "$HERE/interlink_roots.py" --node "$NODE"; rc=$?
case $rc in
  0) echo "VERDICT: as claimed" ;;
  1) echo "VERDICT: NOT as claimed" ;;
  *) echo "VERDICT: inconclusive" ;;
esac
exit $rc
