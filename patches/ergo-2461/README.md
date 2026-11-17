# A proposed deployment cutover for ergoplatform/ergo#2461, as a patch on its head

`cutover.patch` is `git diff` against the PR head `97aa022687078726740785d3f1bce9756daf4f5f` (production paths
only: `ergo-core/src/main` and `src/main`, 54 lines over 5 files), for the `pr-scenario` workflow's `extra_patch`
input (candidate only: the candidate becomes the build base + the PR's diff + this patch).

#2461 changes what the interlink proof inside a NiPoPoW proof is checked against. Nodes on the two sides of the
change reject each other's proofs, and an upgraded node stores its proof under a new key, so it has nothing to
serve until its next proof height. The patch adds one constant and three uses of it:

| where | change |
|---|---|
| `Version.NipopowBoundProofVersion` | the first version that builds and checks the new proof form. `6.0.12` here is a placeholder for whatever release ships #2461 |
| `NipopowSupportFilter` | a joining node asks for proofs only from peers announcing at least that version |
| `ErgoNodeViewSynchronizer.sendNipopowProof` | a peer announcing an earlier version is answered with the proof the node's previous version stored, if any |
| `HeadersProcessor` | once per process, on the first header applied after the header chain is synced: if no proof is stored in the new form and one is stored in the old form, rebuild it in the new form for the same suffix head |

Measured with `diffrun/scenarios/nipopow-cutover.json`: serving peers build their stored proof on the base jar,
are restarted in place on the candidate jar, and a joiner on the new or the old jar asks them for a proof. Read
against a run of the same scenario without `extra_patch` (the PR alone).

`rebuild.patch` is the last row alone (the `HeadersProcessor` hunk, 36 added lines, one file), plus a warning
when a stored proof cannot be rebuilt: an upgraded node rebuilds its stored proof once, with no version constant
and no change to whom a node asks or what it serves to whom. Same base, same input.

No unit tests yet; a prototype for measurement, not a filed change.

## Another option: keep the deployed proof form (`keep-deployed-form.patch`)

`keep-deployed-form.patch` is `git diff` against the same PR head (production paths only, 74 added and 12 removed
lines over 6 files), for the same `extra_patch` input. It is a different answer to the same rollout question, and
is not meant to be combined with the two patches above.

The whole-extension proof #2461 builds and the interlinks-only proof deployed nodes build are the same bytes for a
block whose extension holds only interlinks. On mainnet they differ at the first block of a voting epoch, whose
extension also holds system parameters (`repro/interlink-roots/` shows it for a served proof). The patch:

| where | change |
|---|---|
| `PopowProcessor.popowHeader` | the database prover builds the interlinks-only proof for a block which starts a voting epoch, the whole-extension proof for every other block |
| `NipopowProof.hasValidProofs` | accepts the interlinks-only proof for such a header and for no other |
| `ErgoHistoryReader`, `PopowProcessor` | the stored proof is written and read under the key deployed nodes use; the second key goes |

It is the production diff of three commits (tests, the exception, the storage key) on branch
`nipopow/keep-deployed-proof-form` of cafebedouin/ergo; `repro/ergo-2461-keep-deployed-form/run.sh` runs the
NiPoPoW suites at each of them.

To be measured with `diffrun/scenarios/nipopow-mixed-accept.json` (a joiner on one jar against servers on the other,
both directions; the same runs as `nipopow-mixed`, expecting the proof to be applied) and with
`diffrun/scenarios/nipopow-cutover.json` (servers upgraded in place, a joiner on the new or the old jar).

Limits, as read: at a voting-epoch start the check is the one deployed nodes apply to every header. The two forms
are the same bytes only while other blocks hold nothing but interlinks.
