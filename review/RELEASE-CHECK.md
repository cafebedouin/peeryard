# Release-candidate check

One command dispatches the network checks a release decision can use, on GitHub-hosted runners:
`bash review/release-check.sh dispatch --pr <release PR> --head <its head> --line <previous release tag>`, then
`bash review/release-check.sh collect` once the runs finish. Base = the previous release tag (byte-identical to the
published jar when built from source); candidate = the tag + the release PR's production diff. First used for
ergoplatform/ergo#2640 (6.0.8 candidate vs v6.0.7).

## The set and how to read each

| set | what runs | the reading |
|---|---|---|
| interop (3x2) | the release and the candidate on one two-node network, each mining while the other follows | `interop: true` in every run of both roles = same chain and UTXO state root both ways. Any false, reproduced, is a finding |
| interop-aa (1x2) | the release with itself | the control: must be true in every run, or interop is void |
| indexer-diff (3x1) | two nodes with `extraIndex = true`, one per jar; settled point, restart, fork | `settled_same`/`restart_same` in every run; `fork_same` only where `fork_rolled_back` is true: a fork point is inconclusive, not a difference, when the follower never switched (the release's known lighter-fork behaviour) |
| fork-convergence (5x2) | a follower on a lighter static fork meets a heavier one | the smoke's verdict only checks that nodes still answer; compare the `switched` counts per role (about half to 70% on these runners for the release) |
| sibling-fork (4x1) | four nodes, two miners behind a slow link | its candidate expectation (`D_confirmed == 0`) is written for that divergence's open fix: a release candidate without the fix reads AGAINST by construction; compare the counts per role and look for a failure on the candidate side only |

## What the set does not cover
REST changes (they can only VOID polling), candidate assembly, mempool, bootstrap, a crash during indexing, rollbacks
deeper than a few blocks. Say so in any report.

## Writing it up
- Pooled tables carry "pooled n differs: not citable" when the dispatch pools more pairs than the scenario file's
  default. The sizes here are fixed in the script before any run; say that, rather than drop the label.
- An unplanned observation (a metric nobody fixed in advance) is recorded, not claimed; confirm it with a sized
  repeat, as the #2640 `trickle` observation was (not confirmed: 3/10 vs 3/10).
- Form of the comment: `review/GUIDE.md` and the house template; the #2640 report is a worked example.
