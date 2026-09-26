# matrix-fork-deep: matrix-fork with the partition held until both miners are MATRIX_FORK_DEPTH (default 20) blocks past
# the cut, on a young chain (height well under 128), so the fork is deeper than the 16-block offset of a full V2 sync
# summary: the case where the lighter side finds no common point unless the summary also carries the genesis header
# (ergo-matrix patch 004, the hunk in ergoplatform/ergo#2529). INCONCLUSIVE if the fork came out shallower than asked.
#   PEERYARD_MATRIX_JAR=<weak-blocks jar> bash rig/rig.sh rig/examples/matrix-fork-deep.json rig/examples/matrix-fork-deep.sh
MATRIX_FORK_DEPTH=${MATRIX_FORK_DEPTH:-20}
# shellcheck disable=SC1091  # sourced from the rig with the hook's own path
. "$(dirname "$RIG_HOOK")/matrix-fork.sh"
