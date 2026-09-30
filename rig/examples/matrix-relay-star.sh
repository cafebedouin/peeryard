# matrix-relay-star: one Matrix miner (A) and two non-mining Matrix followers (B, C), all linked, 0 ms: does each input
# block A mines reach the followers? The setting of ergoplatform/ergo#2597 (a miner relays only to peers whose last
# SyncInfo put them within two blocks of its height). The run, the relay analysis (per follower: mined / sent /
# received, and how many sends the stale-height rule predicts) and the PASS rule are in matrix-compat.sh.
# shellcheck source=rig/examples/matrix-compat.sh
source "$(dirname "$(readlink -f "$HOOK")")/matrix-compat.sh"
