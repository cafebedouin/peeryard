# Proposed changes to ergoplatform/ergo#2641, as patches on its head

Each file is `git diff <PR head> <variant> -- src/main` against head `2201236403cf4de322f770865099a71bc622c207`, for the
`pr-scenario` workflow's `extra_patch` input (candidate only: the candidate becomes base + PR diff + this patch, the base
arm stays the plain line; each variant is read against a run of the PR alone on the same line and scenario). Measured with
`diffrun/scenarios/relay-floor*.json` (a relay with a lower fee floor) and `floor-spam.json` (a peer forwarding only
sub-floor transactions).

| file | change | what it is for |
|---|---|---|
| `floor20k.patch` | `MinDeclinedTxCost` 200,000 → 20,000 | a peer is parked at 500 declines per block instead of 50, above every per-peer peak reported in the thread |
| `policy-measured.patch` | a decline by the node's own fee floor is charged at its measured cost; the floor stays for every other decline (`ProcessingOutcome.Declined.policy`, `DeclinedTransaction.policy`) | a relay is not charged for its neighbour's policy; a peer sending sub-floor transactions is throttled only by their real cost |
| `keep-declined.patch` | declined ids stay in the table for 10 blocks instead of being cleared on every block (`DeclinedKeepBlocks`) | a re-announced declined id is neither re-requested nor re-charged, removing the backlog growth seen at sustained load |

## On the merged quota (v6.0.8 and later)

#2641 is merged and released in v6.0.8, and its base branch is gone, so the patches below are against a release, not
the PR head: `git diff <tag> <variant> -- src/main`, run with `pr-scenario.yml`'s patch mode (`extra_patch` with `pr`
empty: the base arm is the line, the candidate the line plus the patch), e.g. `line=v6.0.8
scenario=relay-floor-12 extra_patch=patches/ergo-2641/reask-refused.patch`.

| file | change | what it is for |
|---|---|---|
| `reask-refused.patch` | the ids a peer announced (or had cached) while over its per-block budget are kept, bounded per peer (500) and in total (5,000), and requested from that peer after the budget reset, one inv-sized request at a time while the processing cache is empty and the global budget is not exhausted | a parked relay's later valid transactions are fetched after the next block instead of being lost when the relay was their only source; the floor and both budgets are unchanged |
