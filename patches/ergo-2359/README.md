# ergoplatform/ergo#2359 on v6.0.10: the arms of a revert table, as patches

Arms for `.github/workflows/ref-specs.yml`, from branch `pruned-catch-up-v6010` on cafebedouin/ergo, head
`4ccc2cd7ab0134e06dd3d020a8c0b3d5597e61d9`, built on ergoplatform/ergo `v6.0.10` `bb40cc5d2fb63b39c2327f4d6b872cb5e3a1f407`.
That branch is #2359's change ported to `v6.0.10`, then a changed IT, new history properties and two production fixes:

```
4385cabfa  Let pruning nodes catch up after being offline longer than blocksToKeep   (#2359's f659a0c96)
ccfb6df81  Use allowLocalConfig in PrunedDigestNodeCatchUpSpec
7e949752a  Restart PrunedDigestNodeCatchUpSpec outside the headers freshness window
6f1a1e85d  Test a restart that moves the floor above the best full block
973f72526  Do not prune the new best full block while catching up below the floor
4ccc2cd7a  Schedule the successor of the best full block near the tip, below the floor
```

Each unit-table patch applies to the head and puts production files back to `v6.0.10` (`git diff <head> v6.0.10 -- <files>`),
so the branch's tests run against that production code. Each run's `tree.txt` gives the tree id after the patch.

| file | applied on | what it changes |
|---|---|---|
| `v6010-production.patch` | head `4ccc2cd7a` | all four production files back to `v6.0.10` (`v6.0.10` production code, the branch's tests) |
| `minus-bstooold-rule.patch` | head | `ValidationRules.scala` only (`bsTooOld` fatal again) |
| `minus-gate.patch` | head | `FullBlockPruningProcessor.scala` only (#2359's gate) |
| `minus-prune-fix.patch` | head | `FullBlockProcessor.scala` only (`973f72526` reverted) |
| `minus-scan-fix.patch` | head | `ToDownloadProcessor.scala` only (`4ccc2cd7a` reverted) |
| `pr2802-instead-of-prune-fix.patch` | head | `FullBlockProcessor.scala` = `v6.0.10` plus #2802's change to it (no `973f72526`) |
| `it-v6010-with-window.patch` | `v6.0.10` `bb40cc5d2` | adds `PrunedDigestNodeCatchUpSpec` as of `ccfb6df81`, with `.withFallback(headerChainDiffConfig(8))` |
| `it-window.patch` | `ccfb6df81` | the same `headerChainDiffConfig(8)` line in the IT (what `7e949752a` adds, without its comment lines) |

The port (`6f1a1e85d`, neither fix) and the head run without a patch. Dispatch, unit table:

```
H=4ccc2cd7ab0134e06dd3d020a8c0b3d5597e61d9; P=patches/ergo-2359
gh workflow run ref-specs.yml -f repo=https://github.com/cafebedouin/ergo -f label=pr2359-v6010-unit -f repeats=1 \
  -f specs='org.ergoplatform.nodeView.history.PrunedHistoryCatchUpSpec org.ergoplatform.nodeView.history.BlockSectionValidationSpecification org.ergoplatform.nodeView.history.VerifyADHistorySpecification' \
  -f arms="base:$H:$P/v6010-production.patch port:6f1a1e85deab8e730bcf5e8edd88ea5c1b8a34ab head:$H minus-rule:$H:$P/minus-bstooold-rule.patch minus-gate:$H:$P/minus-gate.patch minus-prune:$H:$P/minus-prune-fix.patch minus-scan:$H:$P/minus-scan-fix.patch with-2802:$H:$P/pr2802-instead-of-prune-fix.patch"
```

IT table (`v6.0.10`, the port before the IT commit, the head):

```
gh workflow run ref-specs.yml -f repo=https://github.com/cafebedouin/ergo -f label=pr2359-v6010-it -f repeats=1 \
  -f it_spec=org.ergoplatform.it.PrunedDigestNodeCatchUpSpec -f it_minutes=30 \
  -f arms="v6010:bb40cc5d2fb63b39c2327f4d6b872cb5e3a1f407:$P/it-v6010-with-window.patch port:ccfb6df81a2092b6140c38be9e91ee489e1a1b8b:$P/it-window.patch head:$H"
```
