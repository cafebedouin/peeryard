# Wallet oracle: does a node's wallet stay correct across a lifecycle event?

Many ergoplatform/ergo pull requests claim the wallet stays correct across a restart, a crash, a fork switch, a
rescan, pruning or a migration, and test it with unit specs only. This oracle checks the claim on a running network
without knowing what the node's code does: one node's wallet (the **subject**, `S`) goes through the event, a second
node holding the same keys (the **reference**, `R`) does not, and once both are settled on the same chain their wallet
views are compared field by field. Any difference is the finding.

Code: `rig/lib/wallet_oracle.sh` (snapshot, settle, compare), `tests/wallet_oracle.sh` (the comparator on fixtures,
no node), `rig/examples/wallet-oracle-restart.{json,sh}`, `rig/examples/wallet-oracle-fork.{json,sh}`.

## Keys: one derivation on both nodes

`ergo.wallet.testMnemonic` (the rig's default for every node) derives from the root key and its direct children;
`/wallet/restore` derives along the EIP-3 path, so the two give different addresses from one mnemonic. Both `S` and `R`
use the rig's default `testMnemonic`, with no `conf` override of it, and the oracle's first step is a precondition:
`/wallet/addresses` on `S` and `R` must be the same non-empty list, or the run is `INCONCLUSIVE` before anything
else happens.

**Mining rewards need the mining switch on both.** Seen on 6.0.6 (2026-10-11, exploratory run on the development host):
a follower with the miner's keys but `ergo.node.mining=false` listed the miner's six addresses and **none** of its 213
unspent reward boxes (balance 0 against the miner's 14,377.5 ERG); the wallet tracks the reward script only on a node
whose mining switch is on. So `S` and `R` both run with `ergo.node.mining=true` and `ergo.node.useExternalMiner=true`
(a `conf` override; the topology's `"mining"` stays false, so the rig does not treat them as miners). An external-miner
node only serves candidates and nobody solves them, so neither ever produces a block, and both wallets track the
rewards of the real miner `M`, which holds the same keys. With that override both saw the same 135 ERG of matured
rewards. A wallet difference between a mining and a non-mining node is configuration, not a finding; the examples
keep `S` and `R` identical in configuration so that the event is the only difference.

## Network

| node | keys | role |
|---|---|---|
| `M` | default test mnemonic (K) | the miner; its rewards land in K, so both wallets hold mined rewards |
| `S` | K | subject: put through the event |
| `R` | K | reference: same keys, same configuration, never put through the event |
| `P` | BIP-39 vector "abandon ... about" (W) | a foreign wallet: receives from `S` (spent boxes) and pays `S` (received payments) |

Only `S` spends from K (so no two wallets race for one box); `M` only mines. The fork example adds a second miner `M2`
on the subject's side of the cut (also K, so the subject's wallet holds rewards from the losing fork that it must drop).

Links: in the restart example every node links to `M` and the three followers link to each other; in the fork example
`R`, `P` and `M2` link to `M`, `S` only to `M2`, and `R` links to `P` (the cut is the `M`-`M2` link). The follower links
are there because the examples stop and start the miner by relaunching it: on 6.0.3 and 6.0.5 builds a follower still
downloading blocks at that moment stalled with its headers at the miner's tip and its full height stuck (15 minutes in
one local run, `HEADERS_AHEAD_FULL_STUCK`); with a second source it caught up in the restart example (twice locally on a
6.0.3 build), though not always in the fork example on a 6.0.5 build (one local run: `R` stuck five blocks below its
three peers). `wo_stop_miner` can wait up to `WO_STOP_WAIT` seconds (default 0) for a
moment when every follower holds the miner's tip before stopping it, and prints how far behind each follower was. A 20 s
default was tried for three hosted rounds: it rarely found such a moment (followers 5-20 blocks behind at almost every
stop) and the miner mined on meanwhile. With it on the fork miners too, the branches from the shared tip were 14-17
blocks (`M2`) and 30-34 (`M`), and in all four fork runs of hosted runs 38193970478 and 38194909713 (6.0.7) `M2` and `S`
stayed on their branch after the heal (`LIGHTER_FORK_NOT_SWITCHING`); in the six fork runs before them (branches of 3-9
and 4-12 blocks) they switched. `S`, two hops from `M` behind `M2`, is the fork example's weak point: in hosted runs
38196671478 and 38198199388 it stopped syncing from `M2` (29 and 25 blocks behind it, no movement for 90-120 s) while
every other node was on `M`'s tip.

## The wallet view (REST, 6.0.6; read from the jar's `api/openapi.yaml`)

| field | endpoint | compared as |
|---|---|---|
| `walletHeight` | `GET /wallet/status` | number (also part of the settle rule) |
| `addresses` | `GET /wallet/addresses` | sorted list |
| `balance` | `GET /wallet/balances` | `balance` and `assets` (the `height` field is the settle height) |
| `balanceUnconfirmed` | `GET /wallet/balances/withUnconfirmed` | the same |
| `unspent` | `GET /wallet/boxes/unspent?minConfirmations=-1&limit=2500&offset=…` (paged until empty) | set of `{boxId, value, assets, inclusionHeight, onchain, creationTransaction}` sorted by box id; `minConfirmations=-1` includes boxes created by mempool transactions |
| `transactions` | `GET /wallet/transactions?minInclusionHeight=0&maxInclusionHeight=<h>` | set of `{id, inclusionHeight}` sorted by id, over the settled height range |
| `scans` | `GET /scan/listAll` | sorted `{scanId, scanName}` (empty on the examples; listed so a scan-related change shows) |

Not compared: `confirmationsNum` / `numConfirmations` (derived from the tip, which the settle rule already pins),
`size`, raw `ergoTree`s and registers (they come with the box id), the full transaction bodies (the id commits to them).
`/wallet/boxes` (spent boxes too) and `/wallet/transactionsByScanId` are left for later: the spent history differs
legitimately after a rescan from a height.

## Settle rule: compare only at a settled point

A snapshot records `/info` (`fullHeight`, `bestFullHeaderId`) before and after reading the wallet, and the node's
mempool ids (`/transactions/unconfirmed`). The comparator reports `INCONCLUSIVE: not settled: <why>`, never `DIFF`,
when any of these holds:
- either node's `/info` changed while its snapshot was read (a block arrived mid-read);
- the two best full block ids differ;
- either node's `walletHeight` differs from its `fullHeight` (the wallet has not caught up with the chain);
- the two mempools hold different transaction ids (a restarted node's pool is empty while its peer still holds the
  pending payment: that is mempool state, not wallet state; the hooks let a block confirm it instead).

`wallet_settle S R [window_s]` polls for that state (every 3 s, default window 120 s) with the miner stopped, in the
manner of `same_state`/`settle_follow`; the hook then takes both snapshots and compares them.

## Verdict

One machine-readable line per run, then one indented line per differing field:
```
[wallet-oracle] SAME@<h>:<n-boxes>
[wallet-oracle] DIFF@<h>: <field>: subject=<...> reference=<...>
[wallet-oracle] INCONCLUSIVE: <why>
```
`DIFF` names the first differing field in the order of the table above. A hook maps `SAME` to `rig_verdict=PASS`,
`DIFF` to `FAIL` and `INCONCLUSIVE` to `INCONCLUSIVE`, so `rig.sh` exits 0, 1 or 3. A positive control is a run that
must FAIL, as in the other examples' controls.

## Events (priority order)

Each event happens while the wallet holds mined rewards past the reward delay (the `current` preset: 10 blocks), a
few received payments (`P` pays `S` three times), at least one spent box (`S` paid `P` three times), and one payment
from `S` that is still unconfirmed at the moment of the event (the miner is stopped, the payment is sent, and both
`S`'s and `R`'s mempools are seen to hold it). After the event the miner mines a few blocks so the pending payment
confirms, stops, and the oracle settles and compares. Restarting the miner to mine empties its pool, and a pool is not
re-gossiped on a timer, so a payment the miner lacks is handed back to it from a peer's pool (`wo_push`: the same signed
transaction, `POST /transactions`; one `[wo] re-submitted` line each time), in the history staging after 60 s and for the
pending payment when the miner starts.

| `WO_EVENT` | example | what happens to `S` | needs netem |
|---|---|---|---|
| `restart` | `wallet-oracle-restart` | `relaunch S` (graceful stop, start, chain and wallet kept) | no |
| `crash` | `wallet-oracle-restart` | `crash S` (SIGKILL), 5 s down, `revive S` | no |
| `rescan` | `wallet-oracle-restart` | `POST /wallet/rescan` with no body (a full rescan), wait for the wallet to catch up | no |
| fork | `wallet-oracle-fork` | `S` and `M2` cut from `M`, `R`, `P`; both sides mine; `S` pays `P` on its side; heal so `S` rolls back to the heavier side | yes (`partition`) |

The zero-delay links of `wallet-oracle-restart` install no netem qdisc, so that example runs on a host without
`sch_netem`; the fork example needs `partition` and so a host with netem (the GitHub-hosted runners).

## Controls

- **A/A (negative):** `WO_EVENT=none` runs the same staging with no event; it must report `SAME`. The fork example's
  A/A (`WO_CONTROL=aa`) keeps the same mining schedule with no cut.
- **Positive:** `WO_EVENT=rescan-from` rescans `S` from 20 blocks below its tip (`POST /wallet/rescan
  {"fromHeight": h-20}`; the API documents that the wallet then does not see boxes below that height). Honest,
  deterministic, a real wallet API, and on a settled chain: it must report `DIFF` (seen in the exploratory run: 37
  unspent boxes on `S` against 101 on `R`). `GET /wallet/deriveNextKey` was the first candidate (one more address on
  `S` only) but 6.0.6 refuses it on a test-mnemonic wallet ("Unable to derive key, wallet is not initialized"). The
  fork example's positive control (`WO_CONTROL=rescan-from`) applies the same rescan after the heal.
- **Comparator self-test:** `tests/wallet_oracle.sh` runs `wallet_cmp` on fixture snapshots under
  `tests/fixtures/wallet-oracle/` for SAME, DIFF (each field), and each not-settled reason; no node.

## Before and after a change: the diffrun scenarios

The oracle needs one jar per run: subject and reference run the same code, and the event is the only difference
between them. To ask what a change does to it, `diffrun/scenarios/wallet-oracle.sh` runs the rig example on each role's
jar (every node of the network on that jar), one fresh network per event, and folds the oracle's verdict lines into one
`RESULT_JSON` (`events`, `events_same`, `events_diff`, `same`). Two manifests, parameters in their env:

| manifest | example | env (defaults) | needs netem |
|---|---|---|---|
| `wallet-oracle-restart` | `wallet-oracle-restart` | `WO_EVENTS="restart crash"` (also `rescan`, `none`, `rescan-from`), `WO_AT=confirmed` (or `pending`) | no |
| `wallet-oracle-fork` | `wallet-oracle-fork` | `WO_EVENTS=fork` (also `none`: no cut; `rescan-from`: fork + positive control) | yes |

Each event keeps the oracle's own verdict line in the run's stdout (`[wallet-oracle-scenario] <event>: [wallet-oracle]
SAME@...` or `DIFF@...`, with its per-field and `explain:` lines); an INCONCLUSIVE event makes the run INCONCLUSIVE and
stops it. The manifests' predicates are the before/after shape: base `any(same == false)`, candidate `all(same == true)`,
so SUPPORTS reads "the base shows a wallet difference after the event, the candidate does not", AGAINST "the candidate
shows one", and NULL with both roles `same` "neither does". On GitHub-hosted runners:
```
gh workflow run pr-scenario.yml -R cafebedouin/peeryard --ref <branch> -f scenario=wallet-oracle-restart \
  -f pr=<N> -f head=<40-hex head> -f line=<release tag or the PR's merge base, 40 hex> \
  -f scenario_env='WO_AT=pending; WO_EVENTS=restart crash' -f shards=5 -f pairs=1
```
`scenario_env` overrides only keys the manifest's env declares (`diffrun/scenario-env.sh`); the effective env is in
`verdict.json`'s provenance. `aa=true` puts the base jar in both roles (the plumbing check, and the release's own rate).
`line` may be a commit: a PR that does not apply on a release is built on its own merge base; when the PR merged its
base branch in and has several merge bases, a `line` that is one of them takes the diff from it.

Applies to (first applications): ergoplatform/ergo#2466 (`wallet-oracle-restart`, `WO_AT=pending`, restart and crash),
ergoplatform/ergo#2514 (`wallet-oracle-fork`). Other open wallet pull requests the examples reach are listed in
[WALLET-ORACLE-REPORT.md](WALLET-ORACLE-REPORT.md).

## Open questions

- Whether a restarted node's empty mempool, once the pending payment confirms, ever leaves the wallet's unconfirmed
  view stale (the settle rule waits it out; a stale view would show as a `balanceUnconfirmed` or `unspent` DIFF).
- Whether a full rescan reproduces the spent-box history (`/wallet/boxes`) as well as the unspent set; not compared yet.
- The fork example's depth is small (a few blocks); a deep rollback (beyond `keepVersions`, 200 by default) is a
  different test.
- Pruned (`blocksToKeep`) and digest subjects: the reference would need the same mode, and a rescan below the pruning
  point is expected to differ; not built.
- Only a JVM node; arkadianet's wallet exists but the rig does not initialize it.
