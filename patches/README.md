# patches/: node fixes peeryard carries until they land upstream

A pull-request review does not use this stack: it builds base and candidate on the PR's own merge base (`AGENTS.md`).
The stack is the reference node the example suite runs on.

Some peeryard scenarios trip over known defects in the released node: a follower that never switches to the
heavier chain, a bootstrap that stalls. A scenario that fails for a known, already-diagnosed reason tests nothing
new, so peeryard carries the fix as a patch, builds its **reference node** from the release plus those patches,
and proposes each fix upstream. When upstream merges a fix and a release ships it, the patch leaves the stack.

The release's own behavior stays visible: every patch names the scenarios that need it, and a scenario can
always be run on the unpatched release jar (`--base` / `--candidate`, or `PEERYARD_JAR` for the rig).

## Lifecycle

One folder per upstream repository or line: `ergo/` (ergoplatform/ergo releases), `ergo-matrix/` (ergoplatform/ergo
`weak-blocks`, checked against the branch head), `ergo-node-rust/` (mwaddip/ergo-node-rust),
`arkadianet/` (arkadianet/ergo). Each holds `patches.json` (the repo, the base release, the clone variable, how to
build, the list) and one upstream-shaped change per `.patch` file, checked and applied in id order (a patch may
build on an earlier one).

| status | meaning | in the stack? |
|---|---|---|
| `candidate` | written, not yet witnessed on a network run | no |
| `proposed` | witnessed; the upstream PR is being prepared or has been opened | yes |
| `under-review` | the upstream PR is open and has had a response | yes |
| `merged-unreleased` | upstream merged it; no release carries it yet | yes |
| `merged-in-<tag>` | upstream shipped it in `<tag>`; kept in the list for the record | no |
| `withdrawn` | a maintainer's response showed it wrong or unnecessary | no |
| `rig-only` | carried for a rig measurement only, never proposed from this tree (e.g. a closed upstream PR); always has `only_for` | only in `stack.sh --for <name>` for a name its `only_for` lists |

Each entry records the upstream PR, the scenarios that need it, the witness, and a `responses` log. A PR is
opened against the branch the upstream maintainers name (for ergoplatform/ergo, the current release branch rather
than `master`; `review/GUIDE.md` rule 11a). A changed PR
means the patch is re-exported and the scenarios that need it are re-run.

**One stack for every test; `only_for` is a temporary exception.** A patch may carry `only_for: [<scenario>]` when it
is needed by that scenario and breaks another. The default stack leaves it out, and `stack.sh --for <scenario>` builds
that scenario's own set; the sweep does this per diffrun scenario. Today: `ergo/003` (#2313) is `only_for:
sibling-fork`, because on the combined stack a miner that holds a competing header whose body never arrives stops
mining (its own block is stored off the best header chain, so the candidate generator's solved block is never
cleared), which wedges `fork-convergence`. The goal is no exceptions (one reference node), and then no patches at all
as fixes land upstream: each exception is reported upstream and removed as soon as the upstream change stops breaking
the other scenarios.

## A fix you cannot publish yet: the private overlay

You will find node defects with this tool, and some will be security problems that go to the project's private channel
(`SECURITY.md`). Until such a report is public, its fix must not appear in a public tree, and a patch file is a
location: it names the file, the lines and the condition. Carry it outside this repository instead. `stack.sh` and
`check.sh` take `PEERYARD_PATCHES_EXTRA=<dir>`, a directory with the same layout as `patches/` (`<repo dir>/patches.json`
plus the patch files) whose entries are stacked after this tree's own, so the reference node you test on carries the
fix while the public tree does not:

```
mkdir -p ~/peeryard-private/ergo
# ~/peeryard-private/ergo/patches.json: {"repo": "ergoplatform/ergo", "base": "<same tag as patches/ergo>",
#   "clone_env": "DIFFRUN_ERGO_CLONE", "build": "diffrun/build.sh", "stack_statuses": ["proposed"],
#   "patches": [{"id": "101", "file": "101-my-fix.patch", "title": "(private)", "status": "proposed", "needed_by": []}]}
PEERYARD_PATCHES_EXTRA=~/peeryard-private bash patches/stack.sh --build ergo
```

Keep the overlay out of any public repository and out of run outputs you share (`review/post.sh` posts only the public
part of a report; `diffrun/lint.sh` can refuse a run that mentions your own private terms, `DIFFRUN_TERMS`). When the
report is public and the PR exists, the patch moves into `patches/` with its upstream reference.

## Commands (from the peeryard root)

```
DIFFRUN_ERGO_CLONE=<ergo clone> bash patches/check.sh ergo [<release tag>]   # still needed? collides? landed?
DIFFRUN_ERGO_CLONE=<ergo clone> bash patches/stack.sh [--build] ergo [<base>]  # combined diff, or the reference jar
DIFFRUN_ERGO_CLONE=<ergo clone> bash patches/stack.sh --build --for sibling-fork ergo   # a scenario's own set
PEERYARD_PATCHES_EXTRA=<overlay dir> bash patches/stack.sh --build ergo            # plus a private overlay (see above)
PEERYARD_ERGO_NODE_RUST_CLONE=<clone> bash patches/check.sh ergo-node-rust
PEERYARD_ARKADIANET_CLONE=<clone> bash patches/check.sh arkadianet
```

`check.sh` compares every patch with the newest release (or the tag given): **NEEDED** (it applies: keep it),
**CONTAINED** (it reverse-applies: it has landed, remove it), **COLLIDES** (neither: the release changed those
lines, so rebase or re-derive it), and the upstream PR's state. Each patch is checked on top of the stacked patches before it, which
also catches two patches that collide with each other; it exits 1 when the stack needs an edit.
`ci/release-watch.yml.example` runs it on every new release.

`sigma-snapshot.sh <ergo commit>` is for the `ergo-matrix/` folder: the `weak-blocks` line pins `sigma-state` to a
`-SNAPSHOT` that is on no public repository, so on a fresh machine `sbt assembly` fails to resolve it. The script reads
the version from the commit's `build.sbt` and, if `~/.ivy2/local` lacks it, builds it from the sigmastate-interpreter
commit the version names (`sbt sigma/publishLocal`, JDK 8, about 3-4 minutes cold). Run it once before
`stack.sh --build ergo-matrix`; the sweep workflow does.

**The `ergo-matrix/candidates/` patches and their base.** A candidate patch is a diff from one `weak-blocks` commit and
applies only there. Unmarked files are diffs from `patches.json`'s `base` (8769baace); a file named `...-on-<commit>.patch`
is a diff from that commit. `patch-compare.yml` and `spec-compare.yml` build on `patches.json`'s base unless the
`matrix_base` input names another full commit (empty, the default, keeps every earlier run reproducible); `builds.txt`
(patch compare) and `tree.txt` (spec compare) record the base each run used. `spec-compare`'s arm `base` is the base
alone, the control. Current on `b2a9e7b00` (`weak-blocks` after ergoplatform/ergo#2666, which carries the ErgoMiner
forward of external solutions, the CandidateGenerator reply for an unusable solution, and #2608):

| on b2a9e7b00 | from (on 8769baace) | dropped as upstream |
|---|---|---|
| `abl-008-010-012-013-014-015-on-b2a9e7b00-v2.patch` | `abl-008-010-012-013-014-015-apifwd.patch` | the ErgoMiner forward and 008's `case _: AutolykosSolution \| _: SolutionFound` reply line |
| `abl-008-010-012-013-014-015-016-on-b2a9e7b00-v2.patch` | `abl-008-010-012-013-014-015-016-apifwd.patch` | the same |
| `abl-008-010-012-013-014-015-2562-on-b2a9e7b00-v2.patch` | `abl-008-010-012-013-014-015-apifwd-2562.patch` (#2562 at e18963ad3) | the same |

The `-v2` files are the earlier `-on-b2a9e7b00.patch` files plus only #2529's matching test hunk (the two SyncInfo V2 "older peer"/"unknown peer" assertions in ErgoNodeViewSynchronizerSpecification, which the stack's patch 004 production hunk makes fail without it); the un-suffixed files stay as they were, for the runs that cite them.

Two adaptations beyond dropping what is upstream, the same in all three: 008's "no candidate" reply for an input-block
solution is `StatusReply.error("...")` (a String, as upstream's own reply at that point), not `StatusReply.error(new
Exception("..."))`, because #2666's ErgoMinerSpec case expects a `StatusReply.ErrorMessage` (the HTTP reply text is the
same); and the first ErgoMiningThreadSpec case waits for `GenerateCandidate` past a subscription, as the file's other
cases do (it failed on 8769baace too). Run them with `matrix_base: b2a9e7b00fd0ff76b0080d1c030b9df30ce768f6`. The
8769baace files stay as they were, for the runs that cite them.

`stack.sh` applies the stacked patches in id order to a scratch worktree of the base and writes one combined diff;
for ergo, `--build` hands that diff to `diffrun/build.sh`, which caches the jar by the diff's sha256, and leaves
`<jar>.stack.json` beside it naming the patches, so `review/provenance.sh` can say "reference node v6.0.6+001". For the Rust
nodes, apply the combined diff to a checkout of the base and `cargo build --release`.

## Current list

Run `patches/check.sh` for the live view; this table is `patches.json` as of the last edit (titles, PRs and statuses come from there):
Three of the entries are one package, the sync ladder: `ergo/001` (V2 sync summaries keyed by tip and mode, #2511),
`ergo-matrix/004` (the genesis anchor and scan-back, #2529) and `ergo/005` (the near-tip floor, #2581, issue #2575),
assembled with a fixture fix for `DeepRollBackSpec` on ergoplatform/ergo#2535 (the comment of 2026-09-26 there gives
the 28-run isolation table on v6.0.7: the spec passes only with a sync-point fix and the scan-back, 20 of 20 with the
fixture fix). `ergo/004` (#2596) is the pruned-digest NiPoPoW stall; `ergo/006` to `009` are four independent one-line concerns found while running the suite on v6.0.7.
The witness column of `patches.json` summarizes runs whose captures are not in this repository (`audits/` is local by
design); a patch of ours is the upstream commit as exported, with its author and co-author trailers.

| repo | id | patch | origin | upstream | status | needed by |
|---|---|---|---|---|---|---|
| ergo | 001 | Key V2 sync summaries by selected tip and requested mode | A. Shannon (production diff only) | ergoplatform/ergo#2511 | under-review | `diffrun fork-convergence`, `diffrun sibling-fork` |
| ergo | 002 | MempoolAuditor: rebroadcast a pooled transaction together with its in-pool ancestors | ours | ergoplatform/ergo#2573 | proposed | `rig reorg-mempool` |
| ergo | 003 | Prevent bestFullBlock/bestHeader divergence on sibling forks | jozanek (production diff only) | ergoplatform/ergo#2313 | under-review, `only_for` sibling-fork | `diffrun sibling-fork` |
| ergo | 004 | Do not start full block download inside a NiPoPoW headers gap | ours | ergoplatform/ergo#2596 | proposed | `rig nipopow-bootstrap (pruned digest variant, to be added)` |
| ergo | 005 | Do not scan below minimal full block height for block sections near the tip | ours | ergoplatform/ergo#2581 | proposed | `rig nipopow-bootstrap` |
| ergo | 006 | Check a header's age against its parent's own height, not the height index | ours | ergoplatform/ergo#2580 | proposed | `diffrun fork-convergence (loaded hosts)` |
| ergo | 007 | Do not request announced ADProofs on a node that stores the UTXO set | ours | ergoplatform/ergo#2585 | proposed | none (a fix the stack carries) |
| ergo | 008 | Drop a requested copy of a modifier already in history instead of penalizing the sender | ours | ergoplatform/ergo#2592 | proposed | none (a fix the stack carries) |
| ergo | 009 | Log a cached copy of a stored modifier as a duplicate, not as permanently invalid | ours | ergoplatform/ergo#2593 | proposed | none (a fix the stack carries) |
| ergo | 010 | Serve a newly mined block's header and sections from memory until it is applied | ours | ergoplatform/ergo#2599 | proposed | `matrix-compat share measurements` |
| ergo | 011 | Reject invalid mining solutions without restart (CandidateGenerator only) | A. Shannon (production diff only) | ergoplatform/ergo#2429 (closed unmerged) | rig-only, `only_for` rig-2429, rig-fairminer | patch-compare `ref_2429`, `ref_fairminer` |
| ergo | 012 | Refresh internal miner work when the PoW message changes (ErgoMiningThread only) | A. Shannon (production diff only) | ergoplatform/ergo#2655 | rig-only, `only_for` rig-fairminer | patch-compare `ref_fairminer` (a fair reference miner for share measurement; not a claim about the released node) |
| ergo-node-rust | 001 | feat(config): add a private devnet network ([proxy] network = "devnet") | ours | mwaddip/ergo-node-rust#28 | proposed | `rig ergo-node-rust-follow`, `rig ergo-node-rust-follow-magic` |
| ergo-node-rust | 002 | feat(p2p): [proxy] magic overrides the devnet's wire magic | ours (on 001) | mwaddip/ergo-node-rust#29 | proposed | `rig ergo-node-rust-follow-magic` |
| arkadianet | 001 | [chain] devnet_magic overrides the devnet's wire magic | ours | arkadianet/ergo#362 | merged-in-v0.9.0 | `rig arkadianet-mine-magic` |
| ergo-matrix | 001 | Full-block route matches only /blocks/{id}, so the input-block transaction routes are reachable | A. Shannon (hunk only) | ergoplatform/ergo#2505 | under-review | `rig matrix-tx` |
| ergo-matrix | 002 | Relay a received input block by id to eligible sub-block peers (receive-side guard + relay) | ours | ergoplatform/ergo#2566 | proposed | `rig matrix-latency` |
| ergo-matrix | 003 | Key V2 sync summaries by selected tip and requested mode (#2511, as patches/ergo/001) | A. Shannon (production diff only) | ergoplatform/ergo#2511 | under-review | `rig matrix-fork` |
| ergo-matrix | 004 | Full V2 sync summaries also carry the genesis header, so a peer always finds a common point | A. Shannon (hunk only) | ergoplatform/ergo#2529 | under-review | `rig matrix-fork (deep-fork runs)` |
