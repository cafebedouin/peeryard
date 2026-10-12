# Wallet workload

A scripted wallet workload with an invariant check after every step. It drives a node's wallet the way an operator
or an application does, through the standard REST API, and checks after each step what must be true of the result:
which boxes were spent, what a token issue minted, what a burn removed, what the pools hold, whether every node ends on
one chain and one state root. The steps are a parameter, so the same mechanism serves any change to the wallet, the
transaction builder, scans, fee estimation or the mempool's conflict handling.

Files: `rig/lib/wallet_workload.sh` (the driver: runs the steps, collects one observation per step),
`rig/lib/wallet_check.jq` (the invariants: every verdict comes from here), `rig/wallet-check.sh` (re-judges saved
observations without a node), `rig/examples/wallet-workload.{json,sh}` (the rig example),
`diffrun/scenarios/wallet-workload{,-plain,-posctl}.json` with `wallet-workload.sh` and
`hooks/wallet-workload.json` (the scenario), `tests/wallet_workload.sh` with `tests/fixtures/wallet-workload/` (the
no-node self-test).

## Network

Three JVM nodes on a full triangle of clean links:

| node | role |
|---|---|
| `M` | mines (`mine_poll` 3 s, about one block per poll on this chain; at 1 s the followers trailed the tip by 10 to 25 blocks) and funds the wallet: `WW_FUND_BOXES` (12) boxes of `WW_FUND_NANOERG` (5 ERG) in one payment; every payment in the workload goes to `M`'s address; `M`'s chain is the reference for "confirmed" |
| `A` | the wallet under test (`ergo.wallet.testMnemonic` = the BIP-39 vector "abandon ... about"); every single-wallet step runs here |
| `B` | the same mnemonic and derivation as `A`: one wallet restored on a second node. It holds the same keys and sees the same boxes. Used by the `resubmit` and `conflict` steps |

The roles are names, not positions: `WW_MINER`, `WW_WALLET`, `WW_TWIN` rename them for another topology. In the rig
example all three run `PEERYARD_JAR`. In the diffrun scenario `M` runs the base jar, `A` this role's jar and `B` the
other role's jar, so every run has both versions on one network and the two-node steps ask whether they agree (a
pair of A/A runs puts one jar everywhere).

## Steps

A step is `kind[:arg]`, repeated with `*N`; a list is separated by spaces or commas
(`"send:3 mint:1000 burn:50 conflict*3"`). The list comes from `WW_STEPS`, else the topology's `workload.steps`, else
the preset `WW_PRESET`:

| preset | steps |
|---|---|
| `full` (default) | `scan send-par:6 send:3 mint:1000 transfer:100 burn:50 fee:6 resubmit:0 resubmit:2 resubmit:8 conflict*3` |
| `aa` | `send:3 mint:1000 transfer:100 burn:50 fee:6`: sequential, no concurrency, no second node involved |
| `posctl` | `mint:1000 burn:50` with `WW_CONTROL=positive` |
| `conflict` | `resubmit:0*3 conflict*3` |

Before the first step the miner matures, pays the funding boxes, and both wallet nodes must reach the miner's tip and
show the payment (`WW_SYNC_S`, 240 s); a run that cannot get there is INCONCLUSIVE, not FAIL. Every step starts from
empty pools (waiting up to 120 s, then going on with a warning). A step that needs n independent inputs (`send`,
`send-par`, `conflict`) first makes sure the wallet holds n confirmed boxes with no token, the miner paying the missing
ones: earlier steps leave the wallet's value in token-carrying change, and a step should not inherit that layout.

| kind (arg) | what it does | invariants (each one a line in the output) |
|---|---|---|
| `send` (n, 3) | n payments `A` → `M`, one at a time, distinct amounts (`/wallet/payment/send`) | `distinct_inputs`: no box is an input of two accepted payments; `accepted_confirmed`: every accepted payment is on `M`'s chain within `WW_CONFIRM_S` (150 s); `rejected_with_reason`: every refused one came with a reason |
| `send-par` (n, 6) | the same n payments fired at once | as `send`; also recorded: refusals whose reason is a double spend or "already in the mempool" (`race_rejects`), and identical transaction ids returned to two requests (`duplicate_ids`) |
| `scan` (k, 2) | compiles `PK(<A's address>) && sigmaProp(HEIGHT > 0)` (a script `A`'s key can spend that the wallet does not track), registers a scan on it with `walletInteraction: off` (`/scan/register`, an `equals` rule on R1), pays it k boxes and waits for them to confirm, pays it one more left unconfirmed, then sends two payments from the wallet: one to `M` it can afford, and one to its own address larger than everything the wallet's own boxes hold but smaller than that plus the unconfirmed scan box (to itself, so a wallet that does spend the box keeps its funds for the later steps) | `scan_tracks_boxes` (the scan sees its boxes); `no_scan_box_spent`: no scan-only box is an input of either payment (a correct wallet refuses the larger one). From this step on, every later step's transactions are checked against the same boxes |
| `mint` (amount, 1000) | an asset issue to `A`'s address through the transaction builder (`/wallet/transaction/generate`, then `/transactions`) | `token_id_is_first_input`: exactly one new token id, equal to the id of the transaction's first input; `minted_amount`; `confirmed`; `wallet_holds_minted` |
| `transfer` (amount, 100) | that token, `A` → `M` | `tx_tokens_conserved` (inputs = outputs for every token); `confirmed`; `sender_delta` = −amount; `receiver_delta` = +amount (wallet balances after the block) |
| `burn` (amount, 50) | a `BurnTokensRequest` for that token | `tx_burns_exactly`: inputs − outputs is exactly {token: amount}, every other token kept; `tx_erg_conserved` (the fee output counted); `confirmed`; `wallet_burned_exactly`: the wallet's tokens change by exactly that; `wallet_erg_only_fee`: its ERG by exactly the fee |
| `fee` (n, 6) | n payments with fees 1..n × `WW_FEE` put a load in the pool; at once `/transactions/getFee` (waits 1, 2, 5, 10, 30 min, 200 bytes), `/transactions/waitTime` (fees 0.001 .. 0.1 ERG) and `/transactions/poolHistogram` are read | `present`; `non_negative`; `getFee_monotone` (a longer wait never costs more); `waitTime_monotone` (a higher fee never waits longer); the histogram is well formed |
| `resubmit` (lag s, 0) | one signed transaction submitted to `A`, then the same bytes to `B` after the lag | `confirmed_once_everywhere` (once on every node's chain, at one height); `gone_from_pools` within `WW_CLEAR_S` (60 s); `no_stall` (every node's height advanced); `one_state_root` (every node's best full block is on `M`'s chain and its state root is the root in `M`'s header at that height, so a follower a few blocks behind the moving tip still agrees; re-read for up to `WW_AGREE_S`, 90 s, when a read races a block) |
| `conflict` | one confirmed box both nodes hold; `A`'s wallet builds a payment from it (`inputsRaw`), `B`'s wallet builds a different payment from the same box; the two are submitted to `A` and `B` at the same moment | `exactly_one_confirmed` (on every node, one of the two once, the other never, the same one everywhere); `gone_from_pools` (neither left in any pool); `no_stall`; `one_state_root` |

A step that could not be exercised (nothing accepted, no token minted yet, a scan that did not register `off`, the two
wallets building the same transaction) is INCONCLUSIVE and judges nothing. The timing-dependent outcomes are recorded,
not judged: whether both conflicting transactions were accepted by their nodes (`in_flight` 2 = two transactions in
flight; 1 = one node had already heard of the other's) and whether the resubmitted transaction was accepted twice.

## Output

One line per step and per invariant, then the verdict line and `RESULT_JSON`:

```
[ww] step 8 resubmit:0: PASS
[ww]     ok   confirmed_once_everywhere: in every node's chain once, at height 118
[ww]     ok   gone_from_pools: no pool holds e90ec94d (cleared after s: {"M":0,"A":0,"B":0})
[ww]     ok   no_stall: every node advanced: {"M":116,"A":109,"B":109} -> {"M":125,"A":118,"B":118}
[ww]     ok   one_state_root: SAME@125:c29ee1bdbf87766e (each node's root = the miner's at its height: M@125 A@118 B@118)
[ww]     info {"lag_s":0,"two_accepted":true,"second_reply":"e90ec94dc308f91e20b254c4fb4805af9a8e52a9503a100db421d7dfae91c3b1"}
...
[wallet-workload] === WALLET-WORKLOAD: PASS (steps 5: 5 pass, 0 fail, 0 inconclusive; control none; conflict two-in-flight 0/0, resubmit both-accepted 0/0) ===
RESULT_JSON {"schema_version":1,"scenario":"wallet-workload","versions":{"M":"6.0.7","A":"6.0.7","B":"6.0.7"},"metrics":{"pass":true,"control_tripped":false,"steps":5,...}}
```
(lines from runs on the v6.0.7 release jar: a resubmit step of the full list, and the verdict of the `aa` list)

The verdict is PASS when every step passes, FAIL when any invariant fails, INCONCLUSIVE when a step or the funding could
not be exercised (no `RESULT_JSON` then: diffrun counts the run INCONCLUSIVE). Metrics: `pass`, `control_tripped`,
`steps`, `steps_pass`, `steps_fail`, `conflict_runs`, `conflict_two_in_flight`, `resubmit_runs`,
`resubmit_two_accepted`, `unresponsive_after`. Each step's observation is kept as
`$RIG_LOG_DIR/wallet-workload/obs_NN.json` and its judgement in `steps.jsonl`; `bash rig/wallet-check.sh <obs>...`
re-judges them offline.

## Controls

- **A/A.** `WW_PRESET=aa` (scenario `wallet-workload-plain`): the sequential steps only. Every invariant must hold on any
  honest node; a failure there is the mechanism's, or the node's, before any concurrency is involved. In diffrun the
  A/A over jars is the usual one: the same jar in both roles (`pr-scenario.yml` with `aa: true`).
- **Positive control.** `WW_PRESET=posctl` or `WW_CONTROL=positive` (scenario `wallet-workload-posctl`): the burn step
  also asserts that the burned amount is still held, which must FAIL. The run's verdict is then `CONTROL-TRIPPED`
  (exit PASS) when that invariant, and only that one, failed; `CONTROL-NOT-TRIPPED` otherwise. It shows that a wallet
  balance read after a confirmed burn is able to fail the check, so a PASS on the real invariant means something.
- **No-node self-test.** `T=$(mktemp -d) bash tests/wallet_workload.sh`: every kind's PASS fixture and each way it must
  FAIL or be INCONCLUSIVE, the control, a run's summary, the step-list parser. `WALLET_CHECK_LIB=<dir>` runs it against
  another copy of `wallet_check.jq`; a copy whose invariants always hold turns every FAIL case into a `MISMATCH`.

## Running it

Locally (one node network per host; the lock queues behind other agents' runs):

```
bash rig/preflight.sh
PEERYARD_JAR=<ergo.jar> bash review/with-lock.sh -- bash rig/rig.sh rig/examples/wallet-workload.json rig/examples/wallet-workload.sh
WW_PRESET=aa PEERYARD_JAR=<ergo.jar> bash review/with-lock.sh -- bash rig/rig.sh rig/examples/wallet-workload.json rig/examples/wallet-workload.sh
WW_STEPS="mint:500 burn:500" ...                     # any step list
```

The example suite (`rig/run-suite.sh`, `rig/examples/suite.tsv`) runs the `aa` list: the full list includes the scan and
conflict steps, whose verdict on a given release is a finding about that release, not a regression of the rig.

Base against candidate (`diffrun/README.md`; the manifests are `mixed_jars`):

```
bash review/with-lock.sh -- bash diffrun/run.sh diffrun/scenarios/wallet-workload.json --base <base.jar> --candidate <cand.jar> --out <dir>
```

Hosted (`pr-scenario.yml`): `scenario=wallet-workload` (or `wallet-workload-plain`, `wallet-workload-posctl`), `pr`,
`head`, `line`, or `aa: true` for the A/A. Measured here (12 cores, v6.0.7): the full list takes about 20 minutes per
run, the `aa` list about 4, the positive control about 2; a pair is two runs. The manifests' timeouts are 2400, 1500 and
1200 s. In the release check
(`review/release-check.sh`) it is one line of `SETS` (with `ref` the branch that carries it until it is on main):

```
wallet-workload	wallet-workload	2	1	false	main
```

## Applies to

The steps were chosen so that these open ergoplatform/ergo pull requests each have a step whose invariant their change
is about; the mechanism has nothing specific to any of them.

| pull request | step | invariant |
|---|---|---|
| #2407 (reserve inputs on send requests) | `send-par` | no box in two accepted payments; refusals carry a reason (and are counted as `race_rejects`) |
| #2518 (minted token identity bound to the final first input) | `mint` | token id = first input's id |
| #2510 (automatic token burning on selected surplus) | `burn` (explicit), `transfer` | exactly the burned amount disappears; no other token moves |
| #2453, #2451 (wallet must not spend boxes tracked only by a scan) | `scan` | no scan-only box among a wallet send's inputs, confirmed or unconfirmed |
| #2450 (fee estimation APIs) | `fee` | answers present, non-negative, monotone |
| #2526 (mempool conflicts removed for every applied transaction) | `conflict` (and `resubmit`) | the losing transaction is gone from every pool within `WW_CLEAR_S` |

## What it does not cover

- Only the JVM node's wallet: the Rust implementations have no wallet API here (`rig/README.md`, *Other implementations*).
- Automatic burning by whitelist (#2510's main path) needs a node configured with `ergo.wallet.tokensWhitelist`; the
  `burn` step uses an explicit `BurnTokensRequest`, so it checks the burn arithmetic, not the whitelist policy.
- The conflict is two honest wallets racing on one box; no node is told anything false and no transaction is
  malformed. Fee competition between the two (replacement by fee) is not staged: both pay the default fee.
- Timing: whether both conflicting transactions are in flight depends on the two submissions beating relay between
  `A` and `B`; `in_flight` records it per step (1 means one node had already heard of the other's transaction). The
  invariants hold either way; link delay (`link_netem`) widens the window if a question needs both in flight.
- Wallet state across restarts, rescans, and digest-mode or pruned wallet nodes.
- The fee checks are about shape and direction, not accuracy: a monotone answer can still be a poor estimate.
