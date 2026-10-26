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

## A floor that moves without a prune (restart), and the fix

`restart-tests.patch` adds two properties to `VerifyADHistorySpecification`: the one above (a block stored ahead of its
parent) and "prune the old floor height after a restart moves the floor". The latter applies heights 1..14, closes the
history and reads it again from its settings (the headers-synced flag is not stored, so it starts false), appends header
15 (fresh: `markHeadersSyncedIfFresh` sets the flag and moves the floor from 4 to 5 before any block is applied), applies
15..20 and checks the same two conditions. With #2802 the next prune starts at the floor the latch stored, so height 4
is kept. `restart-fix.patch` adds a commit that stores the height below which sections are gone (written when the
history is read, for a node with full blocks and no record yet, and after each successful prune) and prunes from there,
plus a third property: the same restart with that record removed first (a database from before the change).
`restart-fix-no-open-record.patch` is the fix without the write when the history is read: the control for the third
property.

| file | applied on | tree | what it is |
|---|---|---|---|
| `restart-tests.patch` | v6.0.10 `f2f932bd6` | `d071eeb0d692b049a313028030b900306f0cef23` | the two properties |
| `restart-tests.patch` | v6.0.9 `9f77ea638` | `760d313f83f524252b07cbf7b80b54a031c957ca` | the two properties (no #2802) |
| `restart-fix.patch` | v6.0.10 `f2f932bd6` | `e4d1bbcc01a65aecba88ede6fc45564903ec1953` | the properties and the fix |
| `restart-fix-no-open-record.patch` | v6.0.10 `f2f932bd6` | `5a4628a6c03af213734ded5d0950af2ba65f5305` | the same without the record written on read |
| `v609-pr2802-restart-fix.patch` | v6.0.9 `9f77ea638` | `97e32c72b3825cf941e0397cfa40ec7cb7a0d1c6` | #2802 (cherry-picked), the properties, the fix |

```
gh workflow run ref-specs.yml -f label=prune-restart-r2 \
  -f arms='v6010-tests:f2f932bd6a0f8b3516a39f45f9f33f41b6b6f47e:patches/ergo-2794/restart-tests.patch v609-tests:9f77ea638e8fe3ce0d0f81e40ce7ddcdd6055871:patches/ergo-2794/restart-tests.patch v6010-fix:f2f932bd6a0f8b3516a39f45f9f33f41b6b6f47e:patches/ergo-2794/restart-fix.patch v6010-fix-no-open-record:f2f932bd6a0f8b3516a39f45f9f33f41b6b6f47e:patches/ergo-2794/restart-fix-no-open-record.patch v609-pr2802-fix:9f77ea638e8fe3ce0d0f81e40ce7ddcdd6055871:patches/ergo-2794/v609-pr2802-restart-fix.patch' \
  -f specs=org.ergoplatform.nodeView.history.VerifyADHistorySpecification -f repeats=1
```

Expected: `v6010-tests` fails the restart property (`Vector(4)`); `v609-tests` fails the step-ahead property (`Vector(5)`)
and passes the restart one; `v6010-fix-no-open-record` fails the third property (`Vector(4)`); `v6010-fix` and
`v609-pr2802-fix` pass every property. An earlier version of these arms (run 40265066158) simulated the latch with a
direct `updateBestFullBlock` call and had no third property; it is in this file's history.
