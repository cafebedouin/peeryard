# indexer-diff: the extra indexer of two jars on one chain

The JVM node's optional extra indexer (`ergo.node.extraIndex = true`) indexes boxes, transactions, addresses and tokens
and serves them under `/blockchain/...`. `indexer-diff` puts two indexing nodes on one chain, X on one jar and Y on
another (or both on the same jar, the A/A control), and compares their answers field by field at settled points. It was
written for the 6.0.8 candidate (ergoplatform/ergo#2640), which changes the indexer's checkpoint recovery, its recovery
after invalidated ancestors, and gates its reads during a rollback; no other peeryard scenario turns the indexer on.

Files:

| file | what |
|---|---|
| `rig/examples/indexer-diff.json` | topology: M mines (no indexer) and X follow `PEERYARD_JAR`, Y runs `PEERYARD_JAR_B`; X and Y follow M on their own links, both with `extraIndex`; three wallets with different keys |
| `rig/examples/indexer-diff.sh` | the hook: content, the settled point, the restart and fork events, the positive control, `RESULT_JSON` |
| `rig/lib/indexer.sh` | reads one node's indexer into a snapshot (JSON) |
| `rig/indexer-cmp.sh` | compares two snapshots; one verdict line |
| `tests/indexer_diff.sh`, `tests/fixtures/indexer-diff/` | the comparator's no-node self-test |
| `diffrun/scenarios/indexer-diff.{sh,json}` | the diffrun scenario (`mixed_jars`), runnable by `pr-scenario.yml` |

## What is compared

A snapshot holds one node's answers to these routes (the same routes in v6.0.7 and the candidate; the candidate's
OpenAPI adds only a `503` answer, `ExtraIndexRecovering`, while the indexer recovers):

| route | kept |
|---|---|
| `GET /blockchain/indexedHeight` | `indexedHeight`, `fullHeight` |
| `GET /blockchain/box/byIndex/<i>` for every `i` below the box count | every indexed box, the full object: id, address, value, assets, registers, `inclusionHeight`, `spentTransactionId`, `spendingHeight`, `spendingProof`, `globalIndex` |
| `GET /blockchain/transaction/byIndex/<i>` for every `i` below the transaction count | every indexed transaction, the full object (inputs and outputs as indexed boxes, `blockId`, `inclusionHeight`, `numConfirmations`, `index`, `globalIndex`, `size`) |
| `GET /blockchain/box/range`, `/transaction/range` (limit = the count) | the global id listings, in the order served |
| `GET /blockchain/token/byId/<id>` for every token id in a box's assets | token info (box id, emission amount, name, description, decimals) |
| `GET /blockchain/box/byTokenId/<id>`, `/box/unspent/byTokenId/<id>` | box ids per token, and the total |
| `POST /blockchain/balance` per address | the `confirmed` balance (nanoERG and tokens); `unconfirmed` is the mempool, not the index, and is left out |
| `POST /blockchain/transaction/byAddress` per address | transaction ids in the order served, and `total` |
| `POST /blockchain/box/byAddress` per address | box ids in the order served, and `total` |
| `POST /blockchain/box/unspent/byAddress` per address | unspent boxes (`boxId`, `value`, `assets`, `globalIndex`, `inclusionHeight`), confirmed only |

The counts are the newest object's `globalIndex` + 1 (`range?limit=1`, then `byId`): v6.0.7 answers an index past the
end with a 500 (`None.get`), so the snapshot never asks one. The addresses are the union of every address in either
node's boxes plus the three wallets' first addresses, so both nodes are asked about the same set; an address one index
does not know answers 404, which is compared like any answer.

`rig/indexer-cmp.sh` flattens both snapshots to leaf paths (an empty array or object is a leaf; a path present on one
side only is a difference with `<absent>` on the other) and compares every path except `meta` (node name and version),
`settle` and `errors`. Output: one line, then up to `--show` (8) lines naming further differing fields:

```
INDEXER-DIFF <point> SAME@<h>:<best full block id> fields=<n>
INDEXER-DIFF <point> DIFF@<field> x=<X's value> y=<Y's value> (<k> of <n> fields differ)
INDEXER-DIFF <point> INCONCLUSIVE <reason>
```

Exit 0, 1, 3; 2 for a usage error.

## Settle rule

A point is compared only when it is settled; otherwise it is INCONCLUSIVE, never SAME or DIFF:
- before reading: M is paused (its mining relaunched off), and M, X and Y report one best full block id, each with full
  height equal to header height, and X's and Y's `indexedHeight` equal to their full height (the hook waits up to 180 s);
- in each snapshot, the settle record (full height, best full block id, `indexedHeight`) read before the queries equals
  the one read after them: nothing moved while the node was read;
- every request answered 200 or 404 (a 503 from a recovering indexer, a 5xx or a timeout is listed in the snapshot's
  `errors` and is not an answer to compare);
- both snapshots are at the same best full block id.

## Points and events

In this order, in one run (`rig/examples/indexer-diff.sh`):
1. **content**: M's rewards mature (reward delay 10 on the `current` preset); M pays X and Y 5 ERG three times each,
   issues a token (`PYT`, 1000 units, through `/wallet/transaction/send` with an asset-issue request) and sends 100 of
   it to X; X pays Y 2 ERG and Y pays X 1 ERG, so each spends a box it received. Wait for every mempool to empty.
2. **settled**: compare. X's snapshot is kept as X0.
3. **restart**: M mines again and pays X 1 ERG; Y is relaunched (TERM, wait for exit, start; its data kept) while M
   mines, so Y indexes the blocks it missed after the restart; M pauses; compare.
4. **positive control**: X0 against Y's snapshot from point 3, with `--positive-control` (the tips may differ; each side
   must still be settled on its own). It must come out DIFF; if it does not, the run is INCONCLUSIVE.
5. **fork** (skip with `INDEXER_DIFF_FORK=0`): the M-Y link is cut; Y mines its own branch from the shared tip, with a
   payment Y -> X confirmed on it; M mines a longer branch; the link is healed and M mines on until Y holds M's block
   at the first forked height and M's height (up to 180 s); M pauses; compare. `fork_rolled_back` records that Y's
   header id at the first forked height changed from its own to M's. When no fork formed (the two ids at that height
   are not different before the heal), the point is INCONCLUSIVE. A release can stay on the lighter branch it already
   holds after the heal (Y never asks for M's heavier chain), which left the point unsettled (INCONCLUSIVE); so when Y
   has not switched `INDEXER_DIFF_SWITCH_S` seconds (default 60) after the heal, Y is relaunched once (graceful, data
   kept), the 180 s wait starts again, and the run records it (`fork_follower_restarted: true` in `RESULT_JSON`, and
   `Y relaunched after the heal: true` in the fork and points lines). A fork point compared after such a relaunch shows
   the indexer across a rollback Y took after a restart, not one it took while running: read it with that flag.

Rig verdict: FAIL on a DIFF at any point; PASS when the settled point is SAME, the positive control DIFF and no point
DIFF; INCONCLUSIVE otherwise. Every verdict line is printed with the prefix `[indexer-diff]` and kept in
`<log dir>/indexer-verdicts.log`; the snapshots are kept under `<log dir>/indexer/<point>/{X,Y}.json` (a diffrun run
keeps only `*.log` of a VALID run: the verdict lines survive, the snapshots do not unless `DIFFRUN_KEEP_WORK=1`).

The events touch Y only. Under diffrun the base role puts the candidate jar on Y and the candidate role puts the base jar
there, so one pair runs the events on each jar.

## Controls

- **A/A**: the same jar on X and Y must give SAME at every point that settles. A difference under A/A means the
  snapshot reads something that is not a function of the chain (an ordering, a time), and the comparison cannot be
  read for that field until it is explained.
- **Positive control**: point 4 above, in every run: one node's view before a payment and a few blocks against the
  other's after. It shows that a real difference in the index reaches the verdict line. The comparator's fixture test
  (`tests/indexer_diff.sh`) adds a changed field, an absent address, and every unsettled case; with `INDEXER_CMP=<copy>`
  it checks a deliberately broken comparator (one that never reports DIFF), which must turn the DIFF cases into
  MISMATCH.

## Running it

Locally (one network per host: through the lock; three JVM nodes, about 1.1 GB):

```
bash rig/preflight.sh 3
# A/A on one jar
bash review/with-lock.sh -- env PEERYARD_JAR=<a.jar> PEERYARD_JAR_B=<a.jar> bash rig/rig.sh rig/examples/indexer-diff.json rig/examples/indexer-diff.sh
# X on a.jar, Y (the node the events touch) on b.jar
bash review/with-lock.sh -- env PEERYARD_JAR=<a.jar> PEERYARD_JAR_B=<b.jar> bash rig/rig.sh rig/examples/indexer-diff.json rig/examples/indexer-diff.sh
# through diffrun (one pair: the base role, then the candidate role, events on each jar in turn)
bash review/with-lock.sh -- bash diffrun/run.sh diffrun/scenarios/indexer-diff.json --base <base.jar> --candidate <cand.jar> --out <dir>
```

A run takes about 5 minutes on the development host (4.5-5 min each for the six diffrun runs of the first measurement),
so a diffrun pair is about 10 minutes. The hook first waits up to 90 s for both indexers to answer `indexedHeight` with a
number: right after bring-up they may not yet (seen once per jar before that wait existed).

On GitHub-hosted runners, `pr-scenario.yml` with `scenario: indexer-diff` (the manifest is public tier, has no
`stop_when`/`max_n`, and validates), e.g. `gh workflow run pr-scenario.yml -f scenario=indexer-diff -f line=v6.0.7 -f pr=2640
-f head=<40-hex head> -f shards=1 -f pairs=1`; `aa: true` runs the base jar in both roles. Not dispatched yet: whether the workflow's
check that the PR's merge-base is an ancestor of the build base passes for a given PR and `line` is a property of that
PR's branch, checked by the build job (the first local candidate was v6.0.7 plus `v6.0.7...<head>`, built with
`diffrun/build.sh`, which the workflow does not do). Size it before dispatching:
the run job's limit is 2 × pairs × 1800 s + 30 min, and a pair is about 10 minutes of three JVM nodes. The manifest's `expect` is
`all(agree == true)` for both roles (`agree` = no point DIFF), so SUPPORTS means no difference was seen in either role,
AGAINST a difference in the candidate role, NULL one in the base role only. A run whose settled point does not settle,
or whose positive control is not DIFF, prints no `RESULT_JSON` and is `INCONCLUSIVE (setup)`. `timeout_seconds` is 1800.

## Limits

- One chain of about a hundred blocks, a dozen transactions, one token: what an indexer does on a short devnet chain,
  not on mainnet's history. The checkpoint and recovery paths the candidate changes are reached here only as far as a
  graceful restart and a shallow rollback reach them; a crash (SIGKILL) mid-indexing and a rollback past an indexer
  checkpoint are not staged.
- The per-address unspent listing is read in one page of `IDX_PAGE` (2000) boxes; a devnet address holds far fewer.
- Reads are taken only at settled points, so a difference that exists only while the indexer catches up (or while the
  candidate answers 503) is not compared; a 503 at a settled point makes the point INCONCLUSIVE and is named.
