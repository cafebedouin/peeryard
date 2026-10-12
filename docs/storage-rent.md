# Storage-rent testing

Storage rent (demurrage) lets anyone collect a box that has not moved for the storage period (mainnet 1,051,200 blocks
= 4 years) by spending it with an empty proof and context variable #127, the index of an output. If the box's value
covers its storage fee (`storageFeeFactor` × the box's size in bytes), the named output must recreate the box (same
script, tokens and registers, creation height = the claiming block's height, value at least the box's value minus the
fee); if it does not, the box may be consumed whole (`ErgoInterpreter.checkExpiredBox`). This is a recurring review
surface (mempool policy, candidate assembly, miner-side collection), so peeryard carries reusable helpers and examples
rather than a per-review script.

## The short-period test build (unavoidable)
The storage period is a compile-time constant, not a votable parameter, so no box ages past it on a devnet in a run.
Testing needs a node built with a short period, and every node on the test network must carry it: a node with the
mainnet period evaluates a claim's empty proof against the box's own script and rejects the block.

- `patches/test/storage-period-60.patch` sets `StoragePeriod` to 60 blocks in both places it is defined:
  `ergo-core` `org.ergoplatform.settings.Constants` (read by miner-side code, e.g. ergoplatform/ergo#2598's claim
  builder) and `ergo-wallet` `org.ergoplatform.wallet.protocol.Constants` (read by the consensus check,
  `ErgoInterpreter.verify`). It is hard-coded: one jar serves one period.
- `patches/test/rent-distinct-outputs-devnet.patch` lowers `StorageRentDistinctOutputsActivationHeight` (the
  `txRentDistinctOutputs` rule from v6.0.7, checked in `ErgoTransaction.validateStateful`) from 1,885,000 to 30, so
  the rule is active before the first possible claim (height 60) instead of never on a devnet.
- Both are TEST-ONLY (`patches/test/README.md`): never proposed upstream, never on a public network. Build a jar with
  both on a base `<ref>` with `diffrun/build.sh <ref> <ref>..<branch with the two commits>`.
- Tell the helpers the period with `PEERYARD_STORAGE_PERIOD=60` (they cannot read a constant from `/info`).

## Rig helpers (`rig/lib/storage_rent.sh`; honest collection, the mechanism's intended use)
- `rent_box <node> <value> [<owner address>] [<assets json>] [<registers json>]`: a holder box paid from the node's
  wallet; prints "boxId creationHeight" once the payment confirms. A foreign owner address (the examples use the
  public test key, secret scalar 1, which no rig wallet holds) models a holder whose box only the storage-rent path
  can spend after the period.
- `rent_issue <node> <amount> <name>`: issue a token to the node's own wallet (for a holder box carrying a token).
- `rent_expired <node> <creationHeight>`; `storage_period <node>`; `storage_fee_factor <node>` (from `/info`).
- `rent_claim <node> <boxId> <value> [<beneficiary tree>] [<fee>]`: build and submit a claim for a box whose value does
  not cover its fee (the box consumed whole: value - fee to the beneficiary, fee to the fee box).
- `fee_tree <node>`: the fee-proposition ergoTree, learned once from a payment.
- `rent_blocks <node> <h0> <h1> <file>` and `rent_audit <file> <storageFeeFactor> [<genesis boxes>]`: every claim
  input in a chain's blocks (empty proof and var #127), each checked against the rule from the blocks alone (the spent
  box looked up among earlier outputs and the genesis boxes; its size computed from its serialization; for a covered
  box, the named output's value, script, tokens, registers R4-R9 and creation height). `box_size_check <node> <boxId>`
  compares that size formula with the node's own serialization (`/utxo/byIdBinary`).
- `rent_bot` / `rent_bots_stop`: competing collectors (below).

## Examples
- `storage-rent` (2 nodes, one jar): create dust boxes owned by a foreign key, age them past the period, claim them
  with `rent_claim`; PASS = claims accepted, mined and the boxes spent. The honest baseline (does the mechanism work on
  this build). Any jar with the short period: `PEERYARD_JAR=<v6.0.7 + both test patches>`.
- `storage-rent-war` (2 nodes): several `rent_bot` collectors with different latencies and fee bids race for the same
  expired boxes on one node; reports submissions per bot, the mempool's double-spend replacement, boxes collected.
- `storage-rent-2598` (3 nodes, mixed jars): miner-side collection from ergoplatform/ergo#2598. C mines with
  `ergo.node.storageRentCollection = true` and `extraIndex = true` (#2598 + both test patches, `PEERYARD_JAR_C`); F1
  follows on v6.0.7 + both patches (`PEERYARD_JAR_F1`); F2 follows on #2598 + both patches with collection off
  (`PEERYARD_JAR_F2`). Holder boxes of several sizes and values (two not covering their fee, two with registers, two
  with a token) are made from C's wallet within the first period, C mines past it, and the hook audits every claim
  in the chain from F1's copy of the blocks, checks each holder box was claimed, compares C's state root with F1's
  and F2's at a settled height, and searches F1's and F2's logs for `invalid` / `SemanticallyFailed` lines.
  `SR2598_CONTROL=off` runs C with collection off: 0 claims, the holder boxes unspent, the same agreement.
  The holder boxes are created before height 60 on purpose: once C's own early reward boxes expire, C's sweep claims
  them in its next candidate and a wallet payment spending one of them is dropped from C's mempool (#2598's
  `application.conf` note).

```
PEERYARD_STORAGE_PERIOD=60 PEERYARD_JAR_C=<2598+test.jar> PEERYARD_JAR_F1=<6.0.7+test.jar> PEERYARD_JAR_F2=<2598+test.jar> \
  bash review/with-lock.sh -- bash rig/rig.sh rig/examples/storage-rent-2598.json rig/examples/storage-rent-2598.sh
```

## Actors: holders and collectors
- **holders**: wallets that own boxes and stay idle, so their boxes age past the period and become collectible by
  anyone (on mainnet, ordinary users who left value sitting). `rent_box <node> <value> <holder-address>` makes one.
- **collectors**: whoever claims expired boxes: transaction-submitting bots (`rent_bot`) or a miner that puts its own
  claims into its candidates (#2598's `storageRentCollection`).

## Competing collectors (the "mempool war")
Real storage rent is contended: several collectors race for the same expiring boxes. `rent_bot` models one honest
collector as a background loop; several give the contest. Tunables:
- N bots, each targeting a chosen node.
- reaction latency per bot (ms): the delay between a box becoming eligible and the bot's submission.
- threshold scramble: bots poll boxes approaching the period and fire once one crosses it (poll ms), so contention
  peaks at the threshold as on mainnet.
- fee bid per bot: extra over the minimum; models fee competition and which claim a miner prefers.
- outputs: per bot claims attempted / accepted / lost-to-collision; mempool churn.
Modeling many honest collectors is the mechanism's normal, contended state; that is what these examples do.

## Witnessed (development host, 2026-10-11; one run each, not an A/A rate)
Jars, each built with `diffrun/build.sh <base> <base>..<base + both test patches>` (patch range sha256 `f52369da…`):
v6.0.7 + test patches, appVersion `6.0.7-1-8d4f8926-SNAPSHOT`, sha256 `4beae3e9…`; ergoplatform/ergo#2598 at
63639222e + test patches, appVersion `6.0.7-65-72b604a3-SNAPSHOT`, sha256 `66cc1604…`.
- `storage-rent` on the v6.0.7 jar: `STORAGE-RENT: PASS (collected 5 expired boxes; all mined and spent)`.
- `storage-rent-2598`: `STORAGE-RENT-2598: PASS (C mined 22 claim txs / 36 claimed boxes, all within the rule; 8/8
  holder boxes claimed; F1 (v6.0.7) and F2 on C's state root: SAME@95:…)`; the control, `SR2598_CONTROL=off`:
  `STORAGE-RENT-2598 CONTROL: PASS (no collection expected: 0 claims, 8/8 holder boxes unspent, F1 and F2 on C's state
  root: SAME@95:…)`.
- diffrun `storage-rent-2598` (n=1): SUPPORTS; base 0 claims, agreement; candidate 38 claims in 23 transactions,
  0 rule failures, 8/8 holder boxes, agreement.
`storage-rent-war` was carried over unchanged and not re-run on this branch.
