# ergo-node-rust-follow-magic: ergo-node-rust-follow on a non-default magic (the topology sets [112,101,101,114]
# on the rust-devnet preset, so the rig writes `[proxy] magic` into the Rust node's config). Needs a build that
# accepts that key (the devnet branch proposed upstream); an older build refuses the unknown key and the run fails.
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/ergo-node-rust-follow.sh"
