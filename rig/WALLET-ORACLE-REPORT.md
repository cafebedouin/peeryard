# Wallet oracle: report (2026-10-11)

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
