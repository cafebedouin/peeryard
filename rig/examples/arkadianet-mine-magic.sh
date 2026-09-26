# arkadianet-mine-magic: arkadianet-mine on a non-default magic (the topology sets [112,101,101,114] on the
# rust-devnet preset, so the rig writes `[chain] devnet_magic` into the Rust node's config). Needs arkadianet v0.9.0
# or later (the key is arkadianet/ergo#362); v0.8.0 refuses the unknown key and the run fails.
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/arkadianet-mine.sh"
