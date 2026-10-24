# Release-candidate check

One command dispatches the network checks a release decision can use, on GitHub-hosted runners:
`bash review/release-check.sh dispatch --pr <release PR> --head <its head> --line <previous release tag>`, then
`bash review/release-check.sh collect` once the runs finish. Base = the previous release tag (byte-identical to the
published jar when built from source); candidate = the tag + the release PR's production diff. First used for
ergoplatform/ergo#2640 (6.0.8 candidate vs v6.0.7).

Its complement, `.github/workflows/release-check.yml` ([docs/release-check.md](../docs/release-check.md)), takes a
release branch or any ref instead of a PR and runs what this set does not: the rig examples on both jars, the upgrade
path, and the two rates pooled per role.

## The set and how to read each

| set | what runs | the reading |
|---|---|---|
| interop (3x2) | the release and the candidate on one two-node network, each mining while the other follows | `interop: true` in every run of both roles = same chain and UTXO state root both ways. Any false, reproduced, is a finding |
| interop-aa (1x2) | the release with itself | the control: must be true in every run, or interop is void |
| indexer-diff (3x1) | two nodes with `extraIndex = true`, one per jar; settled point, restart, fork | `settled_same`/`restart_same` in every run; `fork_same` only where `fork_rolled_back` is true: a fork point is inconclusive, not a difference, when the follower never switched (the release's known lighter-fork behaviour). The hook relaunches the follower once when it has not switched 60 s after the heal; `fork_follower_restarted: true` marks a fork point compared after that relaunch (a rollback taken after a restart, not while running): count those apart |
| fork-convergence (5x2) | a follower on a lighter static fork meets a heavier one | the smoke's verdict only checks that nodes still answer; compare the `switched` counts per role (about half to 70% on these runners for the release) |
| sibling-fork (4x1) | four nodes, two miners behind a slow link | its candidate expectation (`D_confirmed == 0`) is written for that divergence's open fix: a release candidate without the fix reads AGAINST by construction; compare the counts per role and look for a failure on the candidate side only |
| crash-consistency (2x1) | a follower SIGKILLed 3-5 times inside block bursts and restarted from its own disk; every node on the role's jar | `same: true` in every run of both roles (S on R's and M's best full block and state root, REST up, no unrecoverable log line) = SUPPORTS. A run counts only with `kills_in_window` at least half of `kills` (else it is INCONCLUSIVE, not SAME); `diff`, `stuck`, `refused` or `logerr` in the candidate role only is a finding to reproduce, in both roles a property of the release line. `restarts_inconsistent` shows how many restarts really landed between the history and state writes |
| wallet-workload (2x1) | the wallet workload's sequential list (`wallet-workload-plain`, preset `aa`: sends, token issue / transfer / burn, fee endpoints), the wallet on the role's jar and restored on the other's | `pass: true` in every run of both roles = SUPPORTS. The `-plain` manifest, not the full `wallet-workload`: the full list adds the concurrent sends and the `scan`, `resubmit` and `conflict` steps, which judge behaviour a release may not have yet (`rig/WALLET-WORKLOAD.md`: their verdict on a release is a finding about that release), so with them the set would not pass on a correct release and a release-check reading would mix the candidate's change with the release's known state. The sequential list must hold on any honest node, so a FAIL there is about the candidate (or the rig). Run the full list separately when a candidate claims to change those steps |
| wallet-oracle-restart (2x1) | the wallet oracle: a subject wallet through a restart and a crash (`WO_EVENTS="restart crash"`, `WO_AT=confirmed`), compared field by field with a reference wallet that went through nothing; every node on the role's jar | the predicates are the before/after shape (base `any(same == false)`, candidate `all(same == true)`), so a candidate that leaves the wallet alone reads **NULL** with both roles `same: true`, which is the expected reading; AGAINST (a DIFF in the candidate role) is a finding to reproduce; SUPPORTS would mean the release shows a wallet difference the candidate removes. Read the `[wallet-oracle] DIFF@...` and `explain:` lines in the runs' stdout before quoting any DIFF |

## What the set does not cover
REST changes (they can only VOID polling), candidate assembly, mempool beyond the wallet workload's sends, bootstrap, a
crash during indexing (crash-consistency runs the full-follower role without the indexer here), rollbacks deeper than a
few blocks, the wallet across a rollback (`wallet-oracle-fork`, not in the set: on v6.0.7 it shows the public #2514
DIFF), storage rent. Say so in any report.

## Writing it up
- Pooled tables carry "pooled n differs: not citable" when the dispatch pools more pairs than the scenario file's
  default. The sizes here are fixed in the script before any run; say that, rather than drop the label.
- An unplanned observation (a metric nobody fixed in advance) is recorded, not claimed; confirm it with a sized
  repeat, as the #2640 `trickle` observation was (not confirmed: 3/10 vs 3/10).
- Form of the comment: `review/GUIDE.md` and the house template; the #2640 report is a worked example.
