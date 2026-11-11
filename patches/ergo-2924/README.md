# ergoplatform/ergo#2924 (and #2349, #2755): remove `FullBlockProcessor.isLinkable`

All four patches apply to `v6.0.11` at `46d0beaa33562f099ff3579036238e78d314ed99` and touch only
`FullBlockProcessor.scala` and `VerifyADHistorySpecification.scala`.

| patch | production file | test file | git tree after `git apply --index` |
|---|---|---|---|
| `pr2924-as-filed.patch` | #2924 | #2924 | `3dead950a621113e9fb9d9e5ef9c94190872dd16` (= #2924 merged into `v6.0.11`) |
| `head-cast.patch` | #2924 | #2924's property, `isInBestFullChain` called through `asInstanceOf[FullBlockProcessor]`, plus #2349's property | `61e3bd67a377c75056a033a1d22afbebb5fcee36` |
| `base-test.patch` | `v6.0.11` (unchanged) | as `head-cast` | `d9247ef6f407ef7d6d7273762fd11fb9c38e90c4` |
| `deletion-only.patch` | `v6.0.11` with only the `isLinkable` guard and helper deleted (the `.ensuring` on `toApply` kept) | as `head-cast` | `30aa828686661758c6eb0daac3304b68deda35c8` |

What each arm reads:
- `pr2924-as-filed`: whether #2924 compiles as filed (its property calls `history.isInBestFullChain`, which `ErgoHistory`
  does not expose).
- `head-cast` / `base-test`: the two gap properties pass with #2924's production change and with the unchanged
  release code (removing `isLinkable` keeps behaviour on this case).
- `deletion-only`: the same properties fail on an `AssertionError` from the `.ensuring` in `processBetterChain`, so the
  length check that replaces `isLinkable` is what keeps an incomplete heavier fork from being applied.

    gh workflow run ref-specs.yml -f label=islinkable-as-filed -f repeats=1 \
      -f arms='pr2924:46d0beaa33562f099ff3579036238e78d314ed99:patches/ergo-2924/pr2924-as-filed.patch' \
      -f specs=org.ergoplatform.nodeView.history.VerifyADHistorySpecification

    gh workflow run ref-specs.yml -f label=islinkable-gap -f repeats=3 \
      -f arms='base:46d0beaa33562f099ff3579036238e78d314ed99:patches/ergo-2924/base-test.patch head:46d0beaa33562f099ff3579036238e78d314ed99:patches/ergo-2924/head-cast.patch deletion:46d0beaa33562f099ff3579036238e78d314ed99:patches/ergo-2924/deletion-only.patch' \
      -f specs=org.ergoplatform.nodeView.history.VerifyADHistorySpecification
