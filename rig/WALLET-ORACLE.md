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
confirms, stops, and the oracle settles and compares.

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

## Open questions

- Whether a restarted node's empty mempool, once the pending payment confirms, ever leaves the wallet's unconfirmed
  view stale (the settle rule waits it out; a stale view would show as a `balanceUnconfirmed` or `unspent` DIFF).
- Whether a full rescan reproduces the spent-box history (`/wallet/boxes`) as well as the unspent set; not compared yet.
- The fork example's depth is small (a few blocks); a deep rollback (beyond `keepVersions`, 200 by default) is a
  different test.
- Pruned (`blocksToKeep`) and digest subjects: the reference would need the same mode, and a rescan below the pruning
  point is expected to differ; not built.
- Only a JVM node; arkadianet's wallet exists but the rig does not initialize it.
