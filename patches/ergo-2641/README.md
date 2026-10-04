# Proposed changes to ergoplatform/ergo#2641, as patches on its head

Each file is `git diff <PR head> <variant> -- src/main` against head `2201236403cf4de322f770865099a71bc622c207`, for the
`pr-scenario` workflow's `extra_patch` input (the candidate becomes base + PR diff + this patch). Measured with
`diffrun/scenarios/relay-floor*.json` (a relay with a lower fee floor) and `floor-spam.json` (a peer forwarding only
sub-floor transactions).

| file | change | what it is for |
|---|---|---|
| `floor20k.patch` | `MinDeclinedTxCost` 200,000 → 20,000 | a peer is parked at 500 declines per block instead of 50, above every per-peer peak reported in the thread |
| `policy-measured.patch` | a decline by the node's own fee floor is charged at its measured cost; the floor stays for every other decline (`ProcessingOutcome.Declined.policy`, `DeclinedTransaction.policy`) | a relay is not charged for its neighbour's policy; a peer sending sub-floor transactions is throttled only by their real cost |
| `keep-declined.patch` | declined ids stay in the table for 10 blocks instead of being cleared on every block (`DeclinedKeepBlocks`) | a re-announced declined id is neither re-requested nor re-charged, removing the backlog growth seen at sustained load |
