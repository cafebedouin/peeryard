# ergoplatform/ergo#2794: a pruned node keeps one height after a block arrives ahead of its parent

Arms for `.github/workflows/ref-specs.yml`. Each adds one property to `VerifyADHistorySpecification`:

```
apply heights 1..14 in order (BlocksToKeep = 11, so the floor is 4)
append 16: it is only stored (best block still 14, floor still 4)
append 15: receiving 15 applies 15 and 16 in one step
apply 17..20 (floor 10)
check: no height in 2 until the floor keeps any block section; every height from the floor to 20 keeps all of them
```

Before #2802, the step that applies 15 and 16 takes its floor from the received block (15 - 10 = 5) and prunes
`(5 - 2) until 5`; the next step's floor is 7 and it prunes `(7 - 1) until 7`, so height 5 is never pruned. #2802
(merged into `v6.0.10` as `a31943552`) prunes `prevMinHeight until newMinHeight` instead.

| file | applied on | tree after `git apply --index` | what it changes |
|---|---|---|---|
| `test.patch` | v6.0.9 `9f77ea638` | `736bd3e23d2eb03d0a1762193565548112d75217` | the property only |
| `test.patch` | v6.0.8 `c1a69f65d` | `4567ebf090ecb49ade0593654a17e4fe60fc32a2` | the property only |
| `test.patch` | v6.0.10 `f2f932bd6` | `bac895c5bedc8fc5364064599ef60b2cafc02b89` | the property only |
| `pr2802-and-test.patch` | v6.0.9 `9f77ea638` | `276c582d6417c9492935b50a96c74b3a937242de` | #2802's commit (`a31943552`, cherry-picked without conflict: production change, its property, its helper) plus the property |

Dispatch:

```
gh workflow run ref-specs.yml -f label=pruning-step-ahead \
  -f arms='v608:c1a69f65df2228ce26b7d1c2360b472ef79fc55c:patches/ergo-2794/test.patch v609:9f77ea638e8fe3ce0d0f81e40ce7ddcdd6055871:patches/ergo-2794/test.patch v609-pr2802:9f77ea638e8fe3ce0d0f81e40ce7ddcdd6055871:patches/ergo-2794/pr2802-and-test.patch v6010:f2f932bd6a0f8b3516a39f45f9f33f41b6b6f47e:patches/ergo-2794/test.patch' \
  -f specs=org.ergoplatform.nodeView.history.VerifyADHistorySpecification -f repeats=1
```

Expected: `v608` and `v609` 18 passed, 1 failed (`Vector(5) was not empty`, the below-floor check); `v609-pr2802` and
`v6010` 20 passed. The first version of the property (without the two checks after appending 16, and with an
any-section keep check) is in this file's history; it gave the same results.
