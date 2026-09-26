# Which scenario fits which change

A pull request's production footprint (`diffrun/build.sh --dry-run <base> master...pr-N -- src/main
ergo-core/src/main ergo-wallet/src/main avldb/src/main` lists the files) tells you which scenario, if any,
can observe its effect. This table is the fit; it is a starting point, not a rule.

| touched paths (ergoplatform/ergo) | what the change can affect | scenario | what it observes |
|---|---|---|---|
| `src/main/scala/org/ergoplatform/network/ErgoNodeViewSynchronizer*`, `.../network/**`, `scorex/core/network/**` | sync negotiation, header and block download, peer handling | `fork-convergence` | does a follower on a lighter static fork switch to a heavier fork it meets |
| `.../nodeView/history/storage/modifierprocessors/{FullBlockProcessor,HeadersProcessor,ToDownloadProcessor}*`, `.../nodeView/history/**` | best-chain choice, block-section application, download scheduling | `sibling-fork` (and `regression/` #525 spec) | best full block vs best header on different forks at one height; agreement after delayed dual mining |
| `.../nodeView/history/**` with reorg or rollback logic, `.../nodeView/state/**` | rollback and re-application | `fork-convergence` (a switch is a rollback) | switched, margin, rollbacks in the node log |
| `.../mining/**`, `.../settings/**` (chain parameters) | block production, difficulty | rig `soak` (rate across the retarget), `mining` | block rate, retarget, quiescence |
| `.../nodeView/mempool/**`, `.../nodeView/wallet/**`, `.../modifiers/mempool/**` | transaction validation, relay, wallet | `txload` | payments accepted, confirmed, counted in blocks, on each jar |
| `.../nodeView/state/**Snapshot**`, `.../modifierprocessors/UtxoSetSnapshotProcessor*`, `.../state/DigestState*` | UTXO-set snapshot bootstrap, digest state across restart | `bootstrap-modes` (digest and pruned followers), plus the node's own `*SnapshotProcessorSpecification`/`*NetworkSpecification` through the revert check | followers settle on the same state root; the added specs guard the change | no diffrun scenario stages `utxoBootstrap`; the rig example `utxo-bootstrap` does (convert it through `lib/rig-scenario.sh` when the PR's question is the bootstrap itself) |
| `.../http/api/**` | REST only | none; the scenarios poll `/info` and `/blocks/at`, so an API change can VOID runs (versions) or break polling, which shows as INCONCLUSIVE | — |
| `src/it/**`, `src/test/**`, docs | tests and docs only | none (nothing to compare on a network) | — |
| protocol version, voting, soft-fork activation, sync between versions | two versions on one network | `interop` (release and candidate on one network, each mining in turn); the activation scenario itself does not exist yet | same chain and state root in both directions |

A mempool change that alters *which* transactions are kept (conflict cleanup, eviction, re-validation) is answered by
the revert check on its spec plus a read of the pool path; `txload` only shows the benign payment path still works.
Producing a conflict on a live network needs a double-spend, which the tool does not stage (CONTRIBUTING.md).

If no row fits, say so in the review instead of running the nearest scenario: a verdict on the wrong scenario
is evidence about nothing.
