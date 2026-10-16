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

Each entry records the upstream PR, the scenarios that need it, the witness, and a `responses` log. A PR is
opened against the branch the upstream maintainers name (for ergoplatform/ergo, the current release branch rather
than `master`; `review/GUIDE.md` rule 11a). A changed PR
means the patch is re-exported and the scenarios that need it are re-run.

**One stack for every test; `only_for` is a temporary exception.** A patch may carry `only_for: [<scenario>]` when it
is needed by that scenario and breaks another. The default stack leaves it out, and `stack.sh --for <scenario>` builds
that scenario's own set; the sweep does this per diffrun scenario. Today there is none. The last one was the old
`ergo/003` (#2313), `only_for: sibling-fork` from 2026-09-25 to 2026-10-15: on the combined stack a miner that held a
competing header whose body never arrived stopped mining, which wedged `fork-convergence`. Upstream replaced #2313
with #2721, which moves the best header to the tying chain instead of waiting for the body (`ergo/010`). The goal is no exceptions (one reference node), and then no patches at all
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

`stack.sh` applies the stacked patches in id order to a scratch worktree of the base and writes one combined diff;
for ergo, `--build` hands that diff to `diffrun/build.sh`, which caches the jar by the diff's sha256, and leaves
`<jar>.stack.json` beside it naming the patches, so `review/provenance.sh` can say "reference node v6.0.6+001". For the Rust
nodes, apply the combined diff to a checkout of the base and `cargo build --release`.

## Current list

Run `patches/check.sh` for the live view; this table is `patches.json` as of the last edit (titles, PRs and statuses come from there):
Three of the entries are one package, the sync ladder: the cache keying (`ergo/010` and `ergo-matrix/003`, #2721;
until 2026-10-15 `ergo/001`, #2511, keyed by tip and mode, whose mode half #2649 made moot in v6.0.8),
`ergo-matrix/004` (the genesis anchor and scan-back, #2529) and `ergo/005` (the near-tip floor, #2581, issue #2575),
assembled with a fixture fix for `DeepRollBackSpec` on ergoplatform/ergo#2535 (the comment of 2026-09-26 there gives
the 28-run isolation table on v6.0.7: the spec passes only with a sync-point fix and the scan-back, 20 of 20 with the
fixture fix). `ergo/004` (#2596) is the pruned-digest NiPoPoW stall; `ergo/006` to `009` are four independent one-line concerns found while running the suite on v6.0.7. The stack is
based on v6.0.8 since 2026-10-15.
The witness column of `patches.json` summarizes runs whose captures are not in this repository (`audits/` is local by
design); a patch of ours is the upstream commit as exported, with its author and co-author trailers.

| repo | id | patch | origin | upstream | status | needed by |
|---|---|---|---|---|---|---|
| ergo | 002 | MempoolAuditor: rebroadcast a pooled transaction together with its in-pool ancestors | ours | ergoplatform/ergo#2573 | proposed | `rig reorg-mempool` |
| ergo | 004 | Do not start full block download inside a NiPoPoW headers gap | ours | ergoplatform/ergo#2596 | proposed | `rig nipopow-bootstrap (pruned digest variant, to be added)` |
| ergo | 005 | Do not scan below minimal full block height for block sections near the tip | ours | ergoplatform/ergo#2581 | proposed | `rig nipopow-bootstrap` |
| ergo | 006 | Check a header's age against its parent's own height, not the height index | ours | ergoplatform/ergo#2580 | proposed | `diffrun fork-convergence (loaded hosts)` |
| ergo | 007 | Do not request announced ADProofs on a node that stores the UTXO set | ours | ergoplatform/ergo#2585 | proposed | none (a fix the stack carries) |
| ergo | 008 | Drop a requested copy of a modifier already in history instead of penalizing the sender | ours | ergoplatform/ergo#2592 | proposed | none (a fix the stack carries) |
| ergo | 009 | Log a cached copy of a stored modifier as a duplicate, not as permanently invalid | ours | ergoplatform/ergo#2593 | proposed | none (a fix the stack carries) |
| ergo | 010 | Move the best header to a tying chain with complete blocks; key the sync info caches by the best header | jozanek (production diff only) | ergoplatform/ergo#2721 | proposed | `diffrun sibling-fork` |
| ergo-node-rust | 001 | feat(config): add a private devnet network ([proxy] network = "devnet") | ours | mwaddip/ergo-node-rust#28 | proposed | `rig ergo-node-rust-follow`, `rig ergo-node-rust-follow-magic` |
| ergo-node-rust | 002 | feat(p2p): [proxy] magic overrides the devnet's wire magic | ours (on 001) | mwaddip/ergo-node-rust#29 | proposed | `rig ergo-node-rust-follow-magic` |
| arkadianet | 001 | [chain] devnet_magic overrides the devnet's wire magic | ours | arkadianet/ergo#362 | merged-in-v0.9.0 | `rig arkadianet-mine-magic` |
| ergo-matrix | 001 | Full-block route matches only /blocks/{id}, so the input-block transaction routes are reachable | A. Shannon (hunk only) | ergoplatform/ergo#2505 | under-review | `rig matrix-tx` |
| ergo-matrix | 002 | Relay a received input block by id to eligible sub-block peers (receive-side guard + relay) | ours | ergoplatform/ergo#2566 | proposed | `rig matrix-latency` |
| ergo-matrix | 003 | Key the sync info caches by the best header (#2721, its cache-key commit only) | jozanek (production diff only) | ergoplatform/ergo#2721 | proposed | `rig matrix-fork` |
| ergo-matrix | 004 | Full V2 sync summaries also carry the genesis header, so a peer always finds a common point | A. Shannon (hunk only) | ergoplatform/ergo#2529 | under-review | `rig matrix-fork (deep-fork runs)` |
