# Wallet oracle: report (2026-10-11, hosted runs 2026-10-12)

The task: a differential oracle for "the node's wallet stays correct across a lifecycle event" (design:
[WALLET-ORACLE.md](WALLET-ORACLE.md)). This page says what was built, what ran (verdict lines verbatim), what did not run
and why, and which open ergoplatform/ergo pull requests each example could check.

## What was built

| file | what |
|---|---|
| `rig/WALLET-ORACLE.md` | design: keys, the network, the compared view and its endpoints (6.0.6 OpenAPI), the settle rule, events, controls, open questions |
| `rig/lib/wallet_oracle.sh` | `wallet_same_addresses` (precondition), `wallet_snapshot`, `wallet_settle`, `wallet_cmp` (the pure comparator), `wallet_oracle` (settle, snapshot, compare; on a DIFF, `explain:` lines), and the staging helpers the examples share |
| `tests/wallet_oracle.sh`, `tests/fixtures/wallet-oracle/` | the comparator on fixture snapshots, no node: SAME, DIFF per field, INCONCLUSIVE per not-settled reason, the ignore-mempool mode (21 checks) |
| `rig/examples/wallet-oracle-restart.{json,sh}` | events `restart`, `crash` (kill -9), `rescan`; A/A `none`; positive control `rescan-from`; `WO_AT=pending` compares before the pending payment confirms |
| `rig/examples/wallet-oracle-fork.{json,sh}` | the fork switch (needs netem); A/A `WO_FORK=0`; positive control `WO_CONTROL=rescan-from` |
| `.github/workflows/wallet-oracle.yml` | every variant on ubuntu-24.04 (netem available), each checked against what it must report |
| rows in `rig/README.md`, `rig/examples/suite.tsv`, `diffrun/scenarios/FIT.md` | |

Two findings shaped the design (both 6.0.6, read from the node and its source):
- **The wallet tracks mining rewards only with the mining switch on** (`WalletCache.scala`: "Mining rewards are being tracked
  only if mining = true in config"). A follower with the miner's keys and `mining=false` listed the same six addresses and
  none of the miner's 213 reward boxes. So `S` and `R` run with `ergo.node.mining=true` and `ergo.node.useExternalMiner=true`:
  both track rewards, neither produces a block.
- **`GET /wallet/deriveNextKey` is refused on a test-mnemonic wallet** ("Unable to derive key, wallet is not initialized"),
  so the positive control is a rescan from a height instead (`POST /wallet/rescan {"fromHeight": tip - 20}`).

Self-tests: `T=$(mktemp -d) bash tests/wallet_oracle.sh` prints `wallet oracle tests: all ok` (21 checks); `shellcheck -x`
(0.10.0) is clean on every new script (hooks with `-s bash -e SC2148,SC2154`, as `.shellcheckrc` says).

## What ran

Where: this session's cloud container (KVM, 4 vCPU, 16 GB, kernel 6.18.44, OpenJDK 21.0.12). Its kernel has no netem
(`CONFIG_NET_SCH_NETEM is not set`); `bash rig/preflight.sh 3` reports every check ok except `netem in a namespace
MISSING` (iproute2 installed by hand in the session). A link with no shaping installs no netem qdisc, so the zero-delay
restart example runs here; a `partition` cannot. These are development runs; the runs to cite belong on GitHub-hosted
runners (`wallet-oracle.yml`).

Node: ergo **6.0.6**, the release asset `ergo-6.0.6.jar`, sha256
`21b9023933b19b98b7eb4d50cb78bcb6c827a0fe65711a00ceaf1b83f8f3a323` (every node; `effective.json` `jar_sha256_16`
`21b9023933b19b98`). Command, each under the run lock:
```
WO_EVENT=<event> [WO_AT=pending] PEERYARD_JAR=ergo-6.0.6.jar \
  bash review/with-lock.sh -- bash rig/rig.sh rig/examples/wallet-oracle-restart.json rig/examples/wallet-oracle-restart.sh
```

### `wallet-oracle-restart` (one run each)

| variant | must | got | verdict line (verbatim) |
|---|---|---|---|
| `WO_EVENT=none` (A/A) | PASS | PASS | `[wallet-oracle] SAME@77:68` |
| `WO_EVENT=restart` | — | PASS | `[wallet-oracle] SAME@71:61` |
| `WO_EVENT=crash` (SIGKILL, 5 s, revive) | — | PASS | `[wallet-oracle] SAME@75:68` |
| `WO_EVENT=rescan` (`fromHeight` 0) | — | PASS | `[wallet-oracle] SAME@73:63` |
| `WO_EVENT=rescan-from` (positive control) | FAIL | FAIL | `[wallet-oracle] DIFF@75: balance: subject={"balance":1283703000000,"assets":{}} reference={"balance":4382701000000,"assets":{}}` |
| `WO_EVENT=none WO_AT=pending` (A/A) | PASS | PASS | `[wallet-oracle] SAME@72:63` |
| `WO_EVENT=restart WO_AT=pending` | — | FAIL | `[wallet-oracle] DIFF@67: balanceUnconfirmed: subject={"balance":3843000000000,"assets":{}} reference={"balance":3842699000000,"assets":{}}` |
| `WO_EVENT=crash WO_AT=pending` | — | FAIL | `[wallet-oracle] DIFF@66: balanceUnconfirmed: subject={"balance":3775500000000,"assets":{}} reference={"balance":3775199000000,"assets":{}}` |

Each run held, at the event: matured rewards (S's balance 3,775-4,181 ERG at the event), three payments S → P (spent boxes), three
P → S (received), and one S → P payment seen in both S's and R's pools. The positive control's other lines:
`unspent: subject=24 (0 only here) reference=65 (41 only here, e.g. 14a1b1b7)`, `transactions: subject=36 (0 only here)
reference=89 (53 only here, e.g. 0c5cc805)`.

**Reading the `WO_AT=pending` DIFFs.** After a restart or a crash, S's pool no longer held the pending payment (`pending
… in S's pool: no`; R's still did), and S's wallet no longer counted it: its three inputs read as unspent again
(`explain: box 0445967a held only by the subject; R's wallet: {"spent":false,…,"inclusionHeight":42,"onchain":true,"scans":[10]};
UTXO set: S=yes R=yes`) and the change box, held by the pool only, is missing (`explain: box 3e9dcc56 held only by the
reference; S's wallet: absent; UTXO set: S=no R=no`). The difference, 0.301 ERG, is the payment (0.3) and its fee. This is the
release not persisting unconfirmed wallet transactions across a restart, the behaviour ergoplatform/ergo#2466 proposes to
change (below); once the payment confirms, the default comparison (`WO_AT=confirmed`) is SAME after both events. With the
same staging and no event, `WO_AT=pending` is SAME, so the DIFF is the event's.

### `wallet-oracle-fork`

| variant | got | what happened |
|---|---|---|
| `WO_FORK=1` (the fork switch) | INCONCLUSIVE | `[rig] HARNESS-FAIL netem 'loss 100%' on M->M2 not applied` then `[wallet-oracle] INCONCLUSIVE: partition M M2 failed`: no netem on this host. **Not run** with a cut. |
| `WO_FORK=0` (A/A), first version of the hook | not a valid control | M resumed mining before it held M2's blocks, built a competing branch, and S rolled back three blocks: the "no event" run held a reorg. The staging was fixed (M must hold M2's tip first; any rollback on S makes the no-cut run INCONCLUSIVE). Its comparison is in *For the operator* below. |
| `WO_FORK=0 WO_CONTROL=rescan-from`, first version | INCONCLUSIVE | `[wallet-oracle] INCONCLUSIVE: S, R, P and M2 did not reach M's tip after the heal`; R and P stayed at full height 43 (headers 45) while M reached 179 (`[rig] CAUSE HEADERS_AHEAD_FULL_STUCK`); not investigated further, a staging or sync matter on this host, not a wallet result |
| `WO_FORK=0` (A/A), fixed hook | INCONCLUSIVE | `[wallet-oracle] INCONCLUSIVE: S -> P payments: 3 sent, P balance 4000000000`: one of S's three history payments had not confirmed into P's balance within 120 s (S sits one hop further from the miner here than in the restart example); the comparison was not reached. Not re-run (budget). |

## What did not run, and why

(As of 2026-10-11. The fork example, repeats and the pull-request runs have since run on hosted runners: *Hosted runs
(2026-10-12)* below.)

- **The fork switch itself** (`WO_FORK=1`) and its positive control: no netem here. Ready for a hosted runner.
- **A valid fork A/A.** Neither no-cut run reached a valid comparison (table above), so the fork example's comparator path
  is not yet shown SAME with no event; the history staging needs a longer wait (or a check of which payment is missing)
  before its first hosted run.
- **Repeats.** Every variant ran once; an A/A rate needs repeats on the runner class (`wallet-oracle.yml` takes
  `repeats` 1-5).
- **Pruning, digest mode, lock/unlock, migration, `/wallet/restore`**: not built (open questions in WALLET-ORACLE.md). The
  examples' wallets come from `testMnemonic`, so code that only runs for a keystore wallet (unlock, cipher parameters,
  keystore directory, unlock migration) is not reached.
- **Spent history** (`/wallet/boxes`) is not compared, only read for `explain:` lines.

To run everything on GitHub-hosted runners (netem present), an operator pushes the branch to the workflow's trigger branch
or, once the workflow is on the default branch, dispatches it:
```
git push origin wallet-oracle:ci/wallet-oracle
gh workflow run wallet-oracle.yml -R cafebedouin/peeryard --ref wallet-oracle -f repeats=3
```
Its summary lists every variant with what it must report and what it got, and fails when one differs; the fork switch
itself (`WO_FORK=1`) is reported, not judged, until the operator's finding below is settled. The two
`WO_AT=pending` event variants are not in the workflow's must-table: on the release they are expected to DIFF (above), on a
PR that persists unconfirmed transactions to be SAME; run them by hand with the PR's jar.

## Hosted runs (2026-10-12)

Everything below ran on GitHub-hosted runners (ubuntu-24.04, netem available) in cafebedouin/peeryard; the sections above
are the earlier development runs. Node: the v6.0.7 release asset `ergo-6.0.7.jar`, sha256
`8616f4051335cf3b7ee3f3099821b7b27b1913bcd8bb5957ed7fc42dde26e9fa`, unless a pull request's jars are named.

### `wallet-oracle.yml`, one run per variant

Nine rounds, each on the branch head of its commit; the staging changed between rounds (below). The last round, run
38198808611 at `0f75740`, verbatim:

| variant | must | got | verdict line |
|---|---|---|---|
| restart-aa | PASS | PASS | `[wallet-oracle] SAME@44:36` |
| restart | PASS | PASS | `[wallet-oracle] SAME@31:24` |
| crash | PASS | PASS | `[wallet-oracle] SAME@42:34` |
| rescan | PASS | PASS | `[wallet-oracle] SAME@59:47` |
| restart-positive | FAIL | FAIL | `[wallet-oracle] DIFF@33: balance: subject={"balance":1412699000000,"assets":{}} reference={"balance":1547699000000,"assets":{}}` |
| pending-aa | PASS | PASS | `[wallet-oracle] SAME@48:35` |
| fork-aa | PASS | PASS | `[wallet-oracle] SAME@85:81` |
| fork | - | FAIL | `[wallet-oracle] DIFF@85: balance: subject={"balance":4989803000000,"assets":{}} reference={"balance":5057303000000,"assets":{}}` |
| fork-positive | FAIL | FAIL | `[wallet-oracle] DIFF@121: balance: subject={"balance":876806000000,"assets":{}} reference={"balance":7487303000000,"assets":{}}` |

Every round's `fork` variant that reached a comparison (rounds 38185046878, 38185580629, 38186050449, 38195830924,
38198199388, 38198808611) was a `DIFF` of the same shape: the subject's balance 67.5 ERG (one block reward) below the
reference's, and one unspent box held only by the reference, in both nodes' UTXO sets (last round: `unspent: subject=76
(0 only here) reference=77 (1 only here, e.g. f8d60b69)`, `explain: box f8d60b69 held only by the reference; S's wallet:
absent; UTXO set: S=yes R=yes`). That is the behaviour ergoplatform/ergo#2514 describes and changes (a matured mining
reward lost from the wallet after a rollback past its maturity height): known and public, recorded here, not a new
finding. Since `fork` itself is a `DIFF` on the release, `fork-positive`'s `DIFF` there shows the comparison runs after a
fork, not that the control alone would produce one.

What failed in earlier rounds and what changed:

| round (run) | variant(s) | got | cause (from the run) | change |
|---|---|---|---|---|
| 38185046878 | fork-aa | INCONCLUSIVE | one of three history payments stayed in S's pool and never reached M | after 60 s, a history payment the miner lacks is handed to it from a peer's pool (`wo_push`, the same signed transaction); the wait is 300 s |
| 38185046878 | restart | INCONCLUSIVE | `not settled: mempools differ`: the pending payment was not mined within 180 s after M's relaunch emptied its pool | `wo_push` for the pending payment when the miner starts |
| 38185580629 | crash | INCONCLUSIVE | the same; its `re-submitted` line showed an error object being posted (a node without the transaction answers with one) | `wo_push` takes only the transaction itself |
| 38193970478, 38194909713 | fork, fork-positive | INCONCLUSIVE | M2 and S stayed on their branch after the heal (`LIGHTER_FORK_NOT_SWITCHING`); branches of 14-17 and 30-34 blocks | the fork miners stop at once again, and the `wo_stop_miner` shared-tip wait (20 s, added for older builds) is off by default |
| 38195830924, 38196671478, 38198199388 | fork-positive, fork, fork-aa | INCONCLUSIVE | S, two hops from M behind M2, stopped syncing below M2 for the whole tip wait (S/M2 full heights 67/201, 95/124, 74/99) | `wo_confirm` stops the miner once it has the blocks and the pending payment is in one, instead of mining on until every follower arrives; the shared-tip wait off |

Two staging changes came from the pull-request runs below rather than from these rounds: links between the followers
(restart example: S, R and P meshed; fork example: R-P), and `WO_TIP_WAIT`. In the round after the last change (run
38198808611) every variant met its expectation; each variant has one run there, so this is not a rate. `S`'s stall
behind `M2` (three of the last five rounds' fork-side INCONCLUSIVEs) is the fork example's open weak point.

### pr-scenario A/A (plumbing)

Run 38186616650 at `f8fd454` (before the follower links): `wallet-oracle-restart`, `aa=true`, `line=v6.0.7`,
`scenario_env=WO_AT=pending; WO_EVENTS=restart crash`, 3 shards x 1 pair. Base jar = `8616f405…` (the release asset's
sha256, built from the tag) in both roles. All 6 runs VALID, every one of the 12 events a `DIFF` on
`balanceUnconfirmed` (e.g. `[wallet-oracle] DIFF@67: balanceUnconfirmed: subject={"balance":3843000000000,"assets":{}}
reference={"balance":3842699000000,"assets":{}}`); pooled verdict `AGAINST` with the A/A label, as the before/after
predicates make it for a jar that shows the DIFF in both roles.

### ergoplatform/ergo#2466 (WO_AT=pending, restart and crash)

Head `090fc7cf2694aeb47d851acb15e18e0edf750e85`; the diff does not apply on v6.0.7 (`ErgoWalletActor.scala`), so the
build base is its merge base `4a7dba059794054fc4c81f5d990dafdeb4f97a49` (v6.0.3-2). Base jar sha256
`d34a43bdc48f17b4089c8549d97ec87a999e54cb9dc5e259f1403a3e36a96186` (6.0.3-2-4a7dba05-SNAPSHOT); candidate (base + the
PR's production diff, 7 files, patch sha256 `c0a0b30e…`) `9b6391239e0d5cf37b632df8abb2eb4e21b4a8e0a018026bdf3ddd1557593e7e`.

- Run 38187138750 (`f8fd454`): 10 of 10 runs INCONCLUSIVE before the event: a follower's full height stuck below its
  headers after M's relaunch (`HEADERS_AHEAD_FULL_STUCK`; locally, 15 minutes without recovery). The follower links came
  from this run.
- Run 38196668166 (`9e5a908`), 5 x 1, pooled verdict `SUPPORTS` with the table's own `[pooled n differs: not citable]`:
  base 4 VALID of 5, each `same=false` with both events `DIFF` on `balanceUnconfirmed` (e.g. `restart: [wallet-oracle]
  DIFF@46: balanceUnconfirmed: subject={"balance":2425503000000,…} reference={"balance":2425202000000,…}`); the fifth's
  restart was `DIFF` and its crash INCONCLUSIVE (`M, S, R, P not on one tip after M stopped`). Candidate 3 VALID of 5,
  each `same=true` with both events `SAME` (e.g. `restart: [wallet-oracle] SAME@52:47`, `crash: [wallet-oracle]
  SAME@39:33`); of the two INCONCLUSIVE, one had its restart `SAME` before the crash staging failed the same way, the
  other failed at that staging step before its first event. No candidate event reported `DIFF`.

### ergoplatform/ergo#2514 (the fork example)

Head `b41a94ca3f752650f0f1215a7e763b2cb889cf44`; two merge bases with master (`a772a5cb`, `5528ef56` = v6.0.5). The diff
from git's pick, `a772a5cb`, would carry v6.0.5's own changes, so the build base is v6.0.5 (`5528ef56`), the other merge
base, and the candidate takes the diff from it (`5528ef56..pr-2514`: 6 production files, the same six GitHub lists,
including the synchronisation prerequisites the PR composes; patch sha256 `109747a5…`). Base jar sha256
`2a7e2978cb09538ed6780d85ae3aa39c1ecce10e5e5a6e0dc3cd8ab087851588` (6.0.5); candidate
`895698db7c0f3e1367c31a196aa29857594346f5bf480ea057ccae9fd3e059bf` (6.0.5-1-dcb61926-SNAPSHOT).

- Run 38187140324 (`f8fd454`), 5 x 1: base 1 VALID (`DIFF`), 4 INCONCLUSIVE at staging (followers stuck after M's
  relaunch); candidate 4 VALID (`SAME`), 1 INCONCLUSIVE (`S, R, P and M2 did not reach M's tip after the heal`).
- Run 38196669727 (`9e5a908`), 5 x 1, pooled verdict `SUPPORTS` with `[pooled n differs: not citable]`: base 2 VALID of
  5, both `DIFF` (`fork: [wallet-oracle] DIFF@108: balance: subject={"balance":6542303000000,…}
  reference={"balance":6609803000000,…}` and `DIFF@111: balance: subject={"balance":6744803000000,…}
  reference={"balance":6812303000000,…}`, each one reward box held only by the reference, in both UTXO sets), 3
  INCONCLUSIVE (`the five nodes are not on one tip after M stopped`). Candidate 3 VALID of 5, all `SAME` (`SAME@115:104`,
  `SAME@117:111`, `SAME@116:105`), 2 INCONCLUSIVE (one at the same staging step, one `S, R, P and M2 did not reach M's
  tip after the heal`). Every VALID run, base and candidate, had one rollback on S.

On both pull requests the base and candidate are older builds than the release, and their INCONCLUSIVE runs are the
staging failures above, not wallet comparisons. Both PR runs used `9e5a908`, before the last two staging changes.

## Open ergoplatform/ergo pull requests the examples could check

Source: the review-queue page (`queue/build.py`, "generated 2026-10-11 18:49 UTC from public GitHub data"), pasted into
this session; the GitHub API to ergoplatform/ergo was not reachable from it, so the open state is the page's, not
re-checked. Selected by title (wallet state, rescan, rollback, restart, persistence); diffs not read. Nothing was posted.

| PR | title | example | how far it reaches |
|---|---|---|---|
| #2466 | Persist unconfirmed wallet transactions and restore them at start-up | `restart`, `crash` with `WO_AT=pending` | the direct differential: DIFF on 6.0.6 (above), SAME expected with the PR |
| #2514 | Keep mining reward maturity in the block wallet checkpoint | `wallet-oracle-fork`; `restart`/`crash`/`rescan` | the subject's wallet holds rewards maturing across the event |
| #2521 | Publish wallet state context after successful persistence | `restart`, `crash` | wallet state after a stop and after a kill |
| #2516 | Keep wallet scan metadata, caches and write acknowledgements consistent | `crash`, `restart` | partly: scans are compared but the examples register none |
| #2659 | Ignore queued catch-up scans during wallet rescan | `rescan` | a full rescan while blocks arrive is not staged (the miner is stopped); a variant would rescan with the miner on |
| #2542 | Coordinate versioned-store transitions with a recovery journal | `crash` | the wallet view after a kill; the store's own recovery is not observed |
| #2523 | Propagate history repair failures before publishing recovered state | `crash` | the same |
| #2541 | Recover paired history insertions before exposing stored objects | `crash` | the same |
| #2513 | Propagate state rollback failures and verify recovered roots (already reviewed with peeryard at its head) | `wallet-oracle-fork` | the wallet across a rollback |
| #2515 | Preserve applied blocks through recursive chain fallback | `wallet-oracle-fork` | a rollback; the recursive fallback itself is not staged |
| #2522, #2508, #2525 | wallet unlock migration failures; unlock with persisted cipher parameters; keystore directory configuration | none yet | keystore wallets only; `testMnemonic` does not reach them |

Not a fit, though the titles name the wallet: #2536, #2538, #2458 change how the REST endpoints filter or page wallet boxes.
Subject and reference run the same jar, so a paging defect shows on both sides and cancels out; a REST comparison
against the base jar is the test for those. Older than 90 days at their heads (unranked on the page): #2362 and #2361
(pruned-mode wallet), #1723 and #2278 (avoiding a rescan from genesis), #2277 (rollback with `keepVersions=0` at restart).

## For the operator

One result of these runs looks like a wallet defect in the released node. Per the task's rule and `SECURITY.md` it is not
written up here; it was handed to the operator directly, and its reproduction was stopped there.

One consequence that belongs here: until that is settled, read any `wallet-oracle-fork` DIFF (with a cut) through its
`explain:` lines before attributing it to the event under test.
