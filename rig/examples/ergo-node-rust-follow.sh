# ergo-node-rust-follow: a second implementation as a follower. A is the JVM reference node (PEERYARD_JAR) mining on
# the rust-devnet chain preset (the private devnet compiled into the Rust nodes); B is an ergo-node-rust binary built with its devnet network (see rig/README.md: the patch is proposed upstream),
# launched by the rig with "kind": "ergo-node-rust" and $PEERYARD_ERGO_NODE_RUST_BIN, dialling A. The rig's oracles are the
# same REST paths for both kinds: /info (fullHeight, headersHeight, bestFullHeaderId, stateRoot, appVersion,
# name), /blocks/at/{h} and /peers/connected (name). A mines until height 40 while B follows (its header ids
# are compared every 5 s); A then stops mining so B can settle at A's height, and the state roots are compared
# at that equal height (a follower that syncs in batches never sits level with a live miner).
#   PEERYARD_JAR=~/ergo-6.0.6.jar PEERYARD_ERGO_NODE_RUST_BIN=<binary> bash rig/rig.sh rig/examples/ergo-node-rust-follow.json rig/examples/ergo-node-rust-follow.sh
# PASS = the two nodes report different appVersions (a JVM and a Rust build really took part), B was on A's
# chain by header id while A mined, B settles at A's height (>= 30) with full height equal to header height and
# the same UTXO state root, and the peer sets match the topology (each side lists the other by name).
# The body is rig/lib/foreign_follow.sh, shared with the other implementation's follow example.
# shellcheck source=rig/lib/foreign_follow.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../lib/foreign_follow.sh"
foreign_follow ergo-node-rust-follow ergo-node-rust
