# ergoplatform/ergo#2794 on v6.0.9: a pruned node keeps one height after a block arrives ahead of its parent

Arms for `.github/workflows/ref-specs.yml`, both applied to ergoplatform/ergo `v6.0.9`
`9f77ea638e8fe3ce0d0f81e40ce7ddcdd6055871`. Both add one property to `VerifyADHistorySpecification`:

```
apply heights 1..14 in order (BlocksToKeep = 11, so the floor is 4)
append 16, then 15: receiving 15 applies 15 and 16 in one step
apply 17..20 (floor 10)
check: no height in 2 until the floor keeps a block section; every height from the floor to 20 keeps all of them
```

On `v6.0.9` the step that applies 15 and 16 takes its floor from the received block (15 - 10 = 5) and prunes
`(5 - 2) until 5`; the next step's floor is 7 and it prunes `(7 - 1) until 7`, so height 5 is never pruned. #2802
(merged into `v6.0.10` as `a31943552`) prunes `prevMinHeight until newMinHeight` instead.

| file | applied on | tree after `git apply --index` | what it changes |
|---|---|---|---|
| `test.patch` | `9f77ea638` | `45026a3bdcf795bc5a461dfe844ed9b1cb0eae6b` | the property only |
| `pr2802-and-test.patch` | `9f77ea638` | `7f0508d078f088b02af99c10d8f26858d0e9a3d8` | #2802's commit (`a31943552`, cherry-picked without conflict: production change, its property, its helper) plus the property |

Dispatch:

```
gh workflow run ref-specs.yml -f label=pruning-step-ahead-v609 \
  -f arms='v609:9f77ea638e8fe3ce0d0f81e40ce7ddcdd6055871:patches/ergo-2794/test.patch v609-pr2802:9f77ea638e8fe3ce0d0f81e40ce7ddcdd6055871:patches/ergo-2794/pr2802-and-test.patch' \
  -f specs=org.ergoplatform.nodeView.history.VerifyADHistorySpecification -f repeats=1
```

Expected from a local run (JDK 8): `v609` 18 passed, 1 failed (`Vector(5) was not empty`); `v609-pr2802` 20 passed.
