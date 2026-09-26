# regression: link shaping inside ergo's own integration-test suite

This track works **within the limits of ergo's existing regression environment**: the Docker-based `src/it`
suite, run with sbt on JDK 8, on the same CI runners. Anything here is meant to become a test the ergo
maintainers own and run themselves. None of it is filed upstream yet; the three split patches are the intended pull
requests, in that order.

That environment can start and stop node containers and cut links, but it cannot delay or drop packets on a
link. The limits we keep to are these:
- the node image is unchanged (no `tc` or `iproute2` in it);
- node containers get no extra capabilities (no `NET_ADMIN` on a node);
- `build.sbt` is unchanged.

## The sidecar

Link shaping comes from a **sidecar**: a short-lived helper container that joins one node container's network
namespace (`--network container:<node>`) and holds `NET_ADMIN` itself. The sidecar image is `alpine` plus
`iproute2` (installed with `apk`, the image's package manager). It is built once, lazily, by the first suite that
shapes a link, so suites that do not shape links pay nothing.

Shaping is per destination. The sidecar puts a `prio` qdisc on the node's interface, with one `netem` band per
target address, selected by a `u32` filter on the destination IP. So only node-to-node traffic is shaped, and
the harness's own REST polling is not. The qdiscs live in the node's namespace and disappear with the container.

The API (`LinkControl`, mixed into the suite's `Docker`): `setLink(from, to, delay, lossPercent)` sets one
direction's delay and/or loss; `setLinkDelay` and `setLinkLoss` are the one-knob forms; `partition(a, b)` cuts
a link with 100% loss both ways and `heal(a, b)` clears it. A partition here is a **soft cut**: the containers
keep running and their TCP sockets stay, which is what a network fault looks like to the node. Upstream's suite
can only stop a container or disconnect it from the docker network, which closes the socket. `connectMillis`
measures one TCP connect over the shaped path, so a test can confirm a delay actually applies before it relies
on it.

## What is here

Two alternative forms of the same change, both for ergo `v6.0.6` (`23aabead8`): **either**
`ergo-it-linkcontrol.patch` (everything in one patch) **or** the three split patches `01-…`, `02-…`, `03-…` applied
in that order (see *Upstreaming plan*). Do not apply both. `ergo-it-linkcontrol.patch` applies cleanly, checked
with `git apply --check`. Together they add or change these files:

| file | what |
|---|---|
| `src/it/.../container/LinkControl.scala` | the sidecar: `setLink`, `setLinkDelay`, `setLinkLoss`, `partition`, `heal`, `connectMillis` |
| `src/it/.../container/Docker.scala` | mixes `LinkControl` into the suite's `Docker` helper |
| `src/it/.../BestChainConsistencyUnderDelaySpec.scala` | example: a regression detector for issue #525 (best full block and best header on different forks at one height), staged with delayed links |
| `src/it/.../PartitionHealSpec.scala` | example: a follower cut off from its miner by a 100%-loss link stops advancing, and catches up on the miner's chain after `heal` |
| `src/it/.../DelayedMinersAgreeSpec.scala` | example: two miners racing across a 500 ms/way delayed cut, each with a follower; after two minutes all four nodes agree on the header a few blocks below the lowest height (green on v6.0.6: 56 blocks, agreement at height 65) |
| `src/it/.../util/ConvergenceWatch.scala` | samples every node's `/info` during a test |
| `src/test/.../util/ConvergenceDiagnosis.scala` (+ spec) | turns a failed convergence into one named cause instead of a bare timeout |
| `src/it/.../ForkResolutionSpec.scala` | uses the watch and the diagnosis in an existing spec |

## Use
```
git -C <ergo clone> checkout v6.0.6 && git -C <ergo clone> apply <peeryard>/regression/ergo-it-linkcontrol.patch
sudo modprobe sch_netem sch_prio cls_u32          # once per host; the sidecar needs these kernel modules
cd <ergo clone> && sbt -Denv=test docker          # the node image, as upstream builds it
sbt "it:testOnly org.ergoplatform.it.PartitionHealSpec org.ergoplatform.it.DelayedMinersAgreeSpec"   # green on v6.0.6
sbt "it:testOnly org.ergoplatform.it.BestChainConsistencyUnderDelaySpec"                             # red by design while #525 is open
```
If the modules or the sidecar image are unavailable, `setLink` returns the reason (tc's own words when `tc`
ran and failed; the Docker error when the helper image could not be built). The example specs then cancel, or
fail when `CI` is set, so a missing module cannot pass silently. The unit spec `ConvergenceDiagnosisSpec` cites
GitHub Actions run ids in comments; they are public runs of ergoplatform/ergo's own CI, kept so a reader can
look up the end states each case reproduces.

## Status of the three example specs, and what they depend on

- **`BestChainConsistencyUnderDelaySpec` is red by design on v6.0.6 and on current master.** Issue #525 is
  open; the spec reproduces it (a build without a fix fails most runs, not every run). It is meant to land
  together with, or after, a fix such as the `isInBestChain` guard that open PR #2313 proposes for
  `FullBlockProcessor.processBetterChain`. Until then it documents the defect; it is not yet a regression guard,
  and it must not be added to a CI job that is expected to be green.
- **`PartitionHealSpec` and `DelayedMinersAgreeSpec` are the regression detectors:** they test behaviour that
  holds today (a cut follower freezes, then catches up; four nodes agree after two miners race across a delayed
  cut), so they are green on v6.0.6 when the host has the netem modules, CANCELED (FAILED under `CI`) otherwise,
  and red only if the behaviour regresses. `DelayedMinersAgreeSpec` uses the same staging as the #525 spec (the
  two specs start separate networks, so they observe the same kind of run, not the same run): together they say
  "consensus held, and the #525 race was or was not observed" under that staging. `DelayedMinersAgreeSpec`
  checks that the delay was set (`tc` succeeded), a minimum block count and the final agreement; it does not
  measure the delay on the path or confirm that a fork race actually occurred in a given run.
- `ConvergenceWatch` builds on `ConvergenceObservations`, which is upstream since v6.0.6 (`src/it/.../util/`);
  the patch adds nothing else outside `src/it` and `src/test`.
- The sidecar image is built at test time from `alpine:3.21.3` (a fixed release, so its `apk` package set is
  fixed too) with `iproute2-minimal`, `iproute2-tc`, `bash`, `coreutils`; shipping a Dockerfile under
  `src/it/resources/` instead is a maintainer's call.

**Upstreaming plan.** As pull requests, not as one patch, and the split is shipped:
`01-linkcontrol-watch-diagnosis-and-green-specs.patch` (`LinkControl`, the `Docker.scala` mix-in,
`ConvergenceWatch`, `ConvergenceDiagnosis` and its unit spec, `PartitionHealSpec`, `DelayedMinersAgreeSpec`;
nothing red), `02-forkresolution-on-convergencewatch.patch` (the `ForkResolutionSpec` change alone),
`03-sibling-fork-525-spec.patch` (the #525 spec, to go with a fix for #525). Each applies on v6.0.6 in that
order (`git apply --check`, cumulative). The three together carry, file for file, the same diff sections as
`ergo-it-linkcontrol.patch`; only the order of the files differs, so the two are not byte-identical but produce
the same tree. The first PR carries the watch and the diagnosis because the green specs use `ConvergenceWatch`,
which uses `NodeSample` and `ConvergenceDiagnosis` from `src/test`. The first patch alone has been run on a
GitHub-hosted runner (sbt `it:testOnly` on the two green specs): `Tests: succeeded 2, failed 0`.

## Relation to the local rig

The rig (`../rig`, `../diffrun`) needs no sidecar: it owns its network namespaces, so it shapes links directly.
It runs anywhere with unprivileged user namespaces and does not need Docker, sbt or an ergo checkout. It is the
faster tool for exploring; this track is how a finding becomes a regression test upstream.
