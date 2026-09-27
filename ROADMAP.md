# peeryard roadmap

What peeryard covers today, what is planned next, and what is out of scope. Contributions to any item are welcome
(`CONTRIBUTING.md`); an item moves to "done" when it ships with a witnessed run.

peeryard tests honest nodes under benign network conditions: delay, loss, partitions, crashes, damaged data
directories, mixed versions and implementations. It does not ship attack tooling (crafted messages, lying or
withholding peers, eclipse set-ups, fuzzers), and none is planned.

## Coverage today, by layer

| layer | covered | examples |
|---|---|---|
| peers | isolation by magic, connectivity, peer sets against the topology, churn (late join, crash, rejoin) | `magic`, `churn`, `netsplit` |
| chain sync | fork choice under delay and partition, digest and pruned followers, UTXO-snapshot and NiPoPoW bootstrap | `fork-convergence`, `sibling-fork`, `bootstrap-modes`, `utxo-bootstrap`, `nipopow-bootstrap` |
| block production | mining control, retarget, orphans under latency, sub-blocks on the Matrix line | `mining`, `soak`, `matrix-pair`, `matrix-mixed` |
| transactions | payments, chained spends, mempool capacity and eviction, re-admission after a reorg | `txload`, `txchain`, `mempool-evict`, `reorg-mempool` |
| state | state-root agreement at a height, recovery from damaged data directories | `same_state` in most examples, `corruption` |
| implementations | the Scala node with two Rust implementations on one network | `arkadianet-*`, `ergo-node-rust-*` |
| pull requests | before/after verdicts with A/A calibration, a review workflow, the fixes peeryard carries | `diffrun/`, `review/`, `patches/` |
| hosted runs | the example suite and one pair per scenario on GitHub-hosted runners (`.github/workflows/sweep.yml`, 2026-09-26: 29 of 33 jobs green, the rest in `rig/examples/experimental.txt` or fixed), the A/A calibration (`aa.yml`) | `.github/workflows/` |
| diagnosis | a named cause for every INCONCLUSIVE or FAIL (node down, stalled, lighter fork not switching, setup step), in the verdict and the run log | `diag/diagnose.py`, `cause` in `verdict.json`; `diag/features.py` ranks per-run features from the kept node logs against the runs' outcomes; `diag/sweep.py` finds what is new in a batch of runs against earlier runs (novelty) or unusual within it; `diag/logmap.py` names the source line behind each log message (both tools take `--source`) |

## Next

First, the conditions upstream already cares about, reproduced here and turned into node-level tests:

- **Upstream's flaky multi-node specs**: `DeepRollBackSpec` timeouts and the `UtxoStateNodesSyncSpec` stall
  (#2452), each with a scenario and a deterministic test for the cause.
- **Delivery expirations under latency** (#2528).

Then the tooling that serves them:

- **Declarative scenario phases**: prefix, partition, freeze, heal and observe as data instead of bash hooks.
- **Topology as a manifest parameter**, so a sweep over shapes (line, star, mesh, clusters) is data.
- **Futility stopping**: end a sequential run once the verdict can no longer change.
- **One timeline collector**: `/info`, peers and mempool per node on one clock, for every run.
- **Activation on a mixed network**: a soft-fork vote and activation with old and new nodes side by side.
- **Download-stall measurement across implementations**: how long a follower waits for block sections from a
  peer of another implementation.
- **Reorg variants**: independent and chained payments in the reorg example.
- **NiPoPoW bootstrap with a pruned digest node.**
- **Clock skew per node** (libfaketime).
- **A designed failing control for every rig example** (`rig/README.md`, *Seen to fail*): the examples not yet seen to
  fail get a control that must FAIL, as `magic` and `netsplit` have.

## Scenario backlog (conditions not yet tested anywhere public)

- Soft partitions: fork resolution when links are slow rather than cut.
- Asymmetric reachability (A to B delivers, B to A drops): sync classification and heal.
- Loss, reorder and duplication at 1-5% on live links.
- Round-trip time near the block interval: sync-status classification under jitter.
- Connect and handshake timeouts against high-latency peers.
- Reorgs under load: repeated shallow reorgs with UTXO, mempool, wallet and indexer compared across nodes.
- Propagation depth on a line topology with per-hop latency.
- Mixed node roles (pruned, digest, snapshot-bootstrapped) under latency and partition.
- Deep forks on young chains: forks deeper than the sync summaries reach (more than 16 blocks below 128, more than
  128 below 512), as on fresh test networks and CI.

## How findings are delivered

A behavior found on a peeryard network is handed over with a node-level test that forces the same state without
timing (the node's own test fixtures), so a maintainer can run it in seconds, and with the scenario that found it.

## Beyond the node

- **The review queue page**: a daily, rules-as-data view of which open pull requests need a review and which need
  a maintainer, with rules anyone can change by pull request.
- **Application-layer protocols on the network**: running a protocol built on Ergo (its off-chain actors and
  contracts) on a peeryard network, to test its liveness and safety assumptions under the same conditions.

## Out of scope

- Attack tooling of any kind (see the top of this file).
- Mainnet-scale load from one host: peeryard is bounded by one machine's memory (about 350 MB per JVM node).
- Deterministic simulation (Jepsen or TLA+ style): a different tool.
