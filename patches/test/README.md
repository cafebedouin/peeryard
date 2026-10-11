# patches/test/: devnet test builds only

**These are not fixes and are never proposed upstream.** Each one changes a mainnet constant so that a behaviour
which takes years or a mainnet height to reach can be exercised on a private devnet within one run. A jar built with
them must never join a public network: it would reject or accept blocks differently from every real node.

They are not part of the reference-node stack (`patches/ergo/`): there is no `patches.json` here, so `stack.sh` and
`check.sh` never pick them up. A test that needs them builds its own jar, e.g. both patches on a base `<ref>`:

```
git -C "$DIFFRUN_ERGO_CLONE" checkout -b test-<ref> <ref>
git -C "$DIFFRUN_ERGO_CLONE" am patches/test/storage-period-60.patch patches/test/rent-distinct-outputs-devnet.patch
bash diffrun/build.sh <ref> <ref>..test-<ref>     # the sidecar records the base sha and the range's patch sha256
```

| file | changes | why |
|---|---|---|
| `storage-period-60.patch` | `Constants.StoragePeriod` from `4 * BlocksPerYear` (1,051,200 blocks) to 60, in both `ergo-core` (`org.ergoplatform.settings.Constants`, read by the miner-side claim code) and `ergo-wallet` (`org.ergoplatform.wallet.protocol.Constants`, read by the consensus check `ErgoInterpreter.verify`, `hasEnoughTimeToBeSpent`) | storage rent: a box becomes collectible by anyone after the storage period, a compile-time constant; with 60 blocks a devnet reaches it in minutes. Every node on the network must carry it, or a node with the mainnet period evaluates a claim's empty proof against the box's script and rejects the block. |
| `rent-distinct-outputs-devnet.patch` | `ValidationRules.StorageRentDistinctOutputsActivationHeight` from 1,885,000 to 30 | from v6.0.7 the `txRentDistinctOutputs` rule (125: the var-127 output indices of one transaction's inputs must be distinct) applies from that height on every network, so a devnet never reaches it. 30 is below 60, the first height at which any box can be claimed under the 60-block period (genesis boxes have creation height 0), so every claim in a run is validated with the rule active; and above 0, so the chain still crosses the activation inside the run. |

Both apply cleanly to v6.0.7 (3a6b00d37) and to ergoplatform/ergo#2598 at 63639222e. Used by `rig/examples/storage-rent*.sh`
(`docs/storage-rent.md`).
