# peeryard

**Status: EXPERIMENTAL (alpha).** peeryard tests the node of Ergo, a proof-of-work blockchain, as a **network** on one
Linux machine: several real node processes, one network namespace each, links you can delay, drop, partition and heal,
nodes you can crash and revive, different versions and implementations side by side, real transactions in the blocks.
A pull request gets a before/after measurement to read next to its code instead of an opinion. No root to run it (the
host setup needs `sudo`; on Ubuntu 23.10+ one sysctl again after each reboot), and no Docker for the local track. Its
author is not a Scala programmer: every review made with it says which of its statements were executed and which were
read, and every number can be re-run from the command that produced it.

**Worth your time if** you review or write Ergo node changes that touch sync, fork choice, the mempool, bootstrap, the
wallet or the network, and want a measured before/after; you have a Linux host (WSL2 works) or a GitHub runner, and
about two hours per verdict. **Not if** you want a quick green check (a verdict is a rate over paired runs, 1.5 to 2.5
hours), or a judgment on design or protocol choices.

## What a result looks like

`fork-convergence` asks whether a follower holding a lighter fork switches to the heavier one once it can see it. On
GitHub-hosted runners (4 vCPU / 16 GB, the class a public repository gets; workflow `aa.yml`):

| node | switched |
|---|---|
| release 6.0.6 | 23 of 40, and 39 of 80 in a second measurement |
| release 6.0.6 + [ergoplatform/ergo#2511](https://github.com/ergoplatform/ergo/pull/2511) alone | 80 of 80 |
| reference node on 6.0.6 (release + the patches peeryard carried) | 40 of 40, and 80 of 80 |
| release 6.0.8 (carries [#2649](https://github.com/ergoplatform/ergo/pull/2649)) | 38 of 38 valid runs (2026-10-16) |

The 6.0.6 misses were the defect being measured, not noise in the rig: the same rig and scenario ran a fixed build at
the ceiling, and the release that shipped the fix sits there too. A rate depends on the machine (6.0.6 switched 54 of 77
on the 2 vCPU / 8 GB class), so rates are compared only within one runner class, and a candidate is judged against the
base measured on the same class. A `SUPPORTS` verdict means the base failed at least twice and the candidate passed
every time; how often that happens for a candidate no better than the base depends on the base's rate (the table in
`diffrun/README.md`). Against a base at the ceiling, as 6.0.8 is here, a scenario can still show a regression
(`AGAINST`) but has no room to show an improvement. Finished runs to look at: `diffrun/examples/`.

## First run

About ten minutes, most of it setup. The full host setup, and what the sysctl gives up, is in
[`docs/running.md`](docs/running.md).
```
sudo apt-get install -y jq iproute2 util-linux procps coreutils curl unzip git python3 default-jre-headless
sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0   # Ubuntu 23.10+ only: turns off a host protection until reboot
sudo modprobe sch_netem
git clone https://github.com/cafebedouin/peeryard && cd peeryard   # every command below runs from here
curl -fsSL -o ~/ergo-6.0.8.jar https://github.com/ergoplatform/ergo/releases/download/v6.0.8/ergo-6.0.8.jar
echo "e1269f3c9b1c75d29f1f1bded720101792db41118757016123de113668353346  $HOME/ergo-6.0.8.jar" | sha256sum -c
bash rig/preflight.sh                                             # can this host run the rig?
PEERYARD_JAR=~/ergo-6.0.8.jar bash rig/rig.sh rig/examples/bringup.json rig/examples/bringup.sh   # two nodes, about a minute
```
It ends with the example's verdict line and the rig's (heights vary):
```
  SYNC-OK: B is on A's chain at height 8 (B.h=8, A.h=27, A keeps mining)
[rig] === hook done (verdict: PASS) ===
```
In a container instead (macOS, or a host you would rather not change): `bash docker/run.sh` builds the image and opens a
shell in it with the flags the rig needs; then the last two lines above, unchanged (`PEERYARD_JAR` set before `run.sh`
is mounted in). `rig/node-release.sh fetch` (needs `gh`) downloads the latest release jar and records its sha256 instead of the
`curl` line.

## Who it is for

- **Ergo node maintainers:** not to run, unless you want to. What reaches you is the output: an issue with a
  reproduction, a pull request whose test fails on the release and passes with the fix, a review that says what was
  executed. The `regression/` track is the one part meant for your own tree: link shaping inside `src/it`, no image
  change.
- **Contributors with open pull requests:** a before/after on your own change, built on its merge base, with the
  release's own base rate beside it (`review/`, `diffrun/`).
- **Anyone who wants to help with node development and does not know where to start:** `AGENTS.md` and `review/` are a
  procedure, not a skill. A laptop, a model and a public pull request produce a review a maintainer can act on, in a
  form that stays the same whoever runs it.
- **Models:** an agent asked to review a pull request starts at `AGENTS.md`; a person starts at *First run* above.

**Review queue:** [cafebedouin.github.io/peeryard](https://cafebedouin.github.io/peeryard/) lists the open
ergoplatform/ergo pull requests that need a review, ranked by public rules (`queue/rules.json`), and
[`/maintainers`](https://cafebedouin.github.io/peeryard/maintainers/) the ones waiting on a maintainer, opening with the
PRs this test suite depends on. Both pages also list open PRs that make the same production change (same `git
patch-id` of the changed lines) and open PRs by different authors on the same issue that touch the same production
files. Generated daily from public GitHub data; a disagreement with a rank is a pull request against the rules. The
same data is published as JSON for tools: [`docs/queue-data.md`](docs/queue-data.md).

## What it is not

peeryard checks whether a change does what it says and whether it holds under bad network conditions. It does not judge
whether a change is the right design, and it has nothing to say about cryptography or protocol choices; those stay with
the maintainers. A verdict is **evidence, not proof**: it summarizes N runs of one scenario on one machine, and is read
with the base rate for its runner class beside it and the known limits in each component's README. Many node defects
only appear with several nodes and imperfect links (forks that never resolve, followers that never switch to the
heavier chain, sync that stalls after a reorg); they are hard to reproduce on one machine and flaky in CI, and peeryard
makes them runnable and repeatable on a network that can mix the Scala node, the two Rust nodes and the Matrix line. It
is a lab for a reviewer, not a replacement for one.

The name is meant like a railyard or a shipyard: a place where the vessels, here peers, are brought in, marshalled,
split and rejoined, inspected, repaired and sent back out.

## Scope

peeryard creates **the conditions honest nodes meet**: delay, loss, partition and heal, crashes and restarts, mining
control, honest votes, wallet payments (conflicting spends from one wallet included), and different node versions side
by side, then checks that the nodes guard and agree. It contains no tooling whose main gain is offensive (crafted or
malformed messages, fuzzers, lying peers), and its scenarios reproduce node behavior that is already public. The rule
and its reasoning: `CONTRIBUTING.md`.

## What is in the tree

| path | what it is | read |
|---|---|---|
| `rig/` | N nodes, shaped links, mining control, mixed versions and implementations, wallet payments, long runs; examples that check the rig itself; `rig/devnet.sh` keeps a devnet up across sessions. Every run records the network it actually ran (`effective.json`). | [`rig/README.md`](rig/README.md), [`rig/PHASES.md`](rig/PHASES.md), [`rig/HOOK_API.md`](rig/HOOK_API.md) |
| `diffrun/` | the scenario runner: build a candidate jar from a git ref, a patch or part of a pull request (hunk isolation by file), run a scenario N paired times, get `SUPPORTS` / `AGAINST` / `NULL` / `DEGENERATE`. `diffrun/scenarios/FIT.md` maps production paths to the scenario that answers for them. | [`diffrun/README.md`](diffrun/README.md) (*Scenarios* is the catalog) |
| `review/` | reviewing a pull request with all of this: pick a PR, run the recipes that fit it, write the report in the house form, three reviews of the draft, four gates, and a human who posts. `AGENTS.md` and `.claude/skills/review-pr` drive it for an agent. | [`review/README.md`](review/README.md), [`review/GUIDE.md`](review/GUIDE.md), [`review/GATES.md`](review/GATES.md) |
| `repro/` | one self-contained reproduction script per upstream issue or PR (a revert check, a mutant, an A/B of two jars or JDKs), run locally or on a hosted runner through `repro-script.yml`. | [`repro/README.md`](repro/README.md) |
| `patches/` | node fixes peeryard carries until they land upstream (nine for the Scala node, on v6.0.8, all in the default stack), the reference node built from the release plus those patches, and a check that flags a patch a new release has made redundant. A pull-request review builds both jars on the PR's own merge base, never on this stack. | [`patches/README.md`](patches/README.md) |
| `diag/` | reading a run: named causes for a failure (`diagnose.py`), recovery costs (`costs.py`), and an opt-in passive wire observer (`wire.py`, `PEERYARD_WIRE=1`). | [`diag/README.md`](diag/README.md) |
| `regression/` | the same link shaping inside ergo's own Docker integration suite (a sidecar with `NET_ADMIN`, node image untouched), with example specs and a failure classifier, as a patch meant to become upstream pull requests. | [`regression/README.md`](regression/README.md) |
| `stack/` | a companion for the review queue: which open PRs share text and which one to land first. Git only; triage, not authority. | [`stack/README.md`](stack/README.md) |
| `queue/` | the review-queue builder behind the published pages: rules, claims, reviewers, the `next` command. | [`docs/queue-data.md`](docs/queue-data.md) |
| `.github/workflows/`, `ci/` | the suite on GitHub-hosted runners: checks on every push, sweeps and A/A calibration, PR scenarios, upstream spec loops, the release check; `ci/` holds workflows to copy into an ergo fork. | [`docs/workflows.md`](docs/workflows.md), [`docs/release-check.md`](docs/release-check.md) |
| `bench/` | `bench/indexer/ExtraIndexerRebuildRateSpec.scala`, an indexer rebuild-rate spec that `indexer-bench.yml` runs on a ref. | [`docs/workflows.md`](docs/workflows.md) |
| `audits/` | where a run's evidence lives (ignored by git except the layout and an example), so a reviewer can answer follow-up questions from what actually ran. | [`audits/README.md`](audits/README.md) |
| `tests/` | the no-node self-tests, seconds each. | [`docs/running.md`](docs/running.md#self-tests-no-node-seconds) |
| `docs/` | host setup and run card, workflows, the release check, the queue data, storage rent. | [`docs/running.md`](docs/running.md), [`docs/storage-rent.md`](docs/storage-rent.md) |
| `ROADMAP.md` | what is covered by layer, what is planned next, the scenario backlog, and what is out of scope. | |

## Two tracks

| | `rig/` + `diffrun/`: **local** | `regression/`: **upstream regression** |
|---|---|---|
| for | exploring, reproducing, before/after checks of a PR on your own machine | turning a reproduction into a test the ergo maintainers can merge and run in CI |
| runs | real node jars, one network namespace per node, no Docker, no root | ergo's own Docker integration suite (`src/it`), sbt, JDK 8 |
| link shaping | `netem` applied directly (the rig owns its namespaces) | a **sidecar** container with `NET_ADMIN` in the node's namespace; node image and containers untouched |
| output | a verdict (`SUPPORTS` / `AGAINST` / `NULL` / `DEGENERATE`) over N paired runs | a ScalaTest spec that passes or fails, with a named failure cause |

## Quick start (local)

After the first run above. Exit codes, run times and where each command writes: [`docs/running.md`](docs/running.md).

**More rig examples.** Real transactions: A pays B from its mining rewards and the payments confirm (a minute or two).
`run-suite.sh` runs several and prints one line each; with no names it runs every example in `rig/examples/suite.tsv`,
skipping those whose artifacts are not set.
```
PEERYARD_JAR=~/ergo-6.0.8.jar bash rig/rig.sh rig/examples/txload.json rig/examples/txload.sh
PEERYARD_JAR=~/ergo-6.0.8.jar bash rig/run-suite.sh bringup txload     # rig bringup: PASS (SYNC-OK) ...
```

**A candidate jar.** Built from a clone of ergo with JDK 8 and sbt (the first build on a host downloads sbt's
dependencies, 10 to 20 minutes; later builds are cached by the diff's hash). The example takes the production diff of
the open pull request [ergoplatform/ergo#2721](https://github.com/ergoplatform/ergo/pull/2721) (`master...pr-2721`:
from the PR's merge base with master to its head) and applies it onto v6.0.8; `-- <paths>` restricts the diff to those
paths (hunk isolation by file). Once #2721 merges the range is empty and `build.sh` stops, so take any open pull
request instead.
```
git clone https://github.com/ergoplatform/ergo ~/src/ergo
git -C ~/src/ergo fetch origin pull/2721/head:pr-2721
CAND="$(DIFFRUN_ERGO_CLONE=~/src/ergo bash diffrun/build.sh v6.0.8 master...pr-2721 -- src/main ergo-core/src/main ergo-wallet/src/main avldb/src/main)"
echo "$CAND"          # the cached candidate jar; its sidecar <jar>.json sits beside it
```
The release jar was built upstream and the candidate here, so a pair of them differs in two ways (the patch and the
toolchain). `diffrun/build.sh v6.0.8` with no patch builds the unpatched base with the same toolchain, which leaves one
difference. To review a pull request, build both jars on the PR's own merge base instead (`AGENTS.md`,
`review/README.md`).

**A two-version devnet that stays up**: the release jar mines, the candidate follows; query, stop, resume, wipe.
```
PEERYARD_JAR=~/ergo-6.0.8.jar PEERYARD_JAR_B="$CAND" bash rig/devnet.sh up rig/examples/mixed.json two
bash rig/devnet.sh curl B /info two           # then: status | logs B | down | up (same command) | wipe
```

**A scenario verdict**: release vs candidate. Below, one paired run of the smoke manifest (about ten minutes); a verdict
to cite comes from the full manifest (8–12 pairs, 1.5–2.5 hours); the smoke manifest checks only that every node still
answers afterwards. The registered version must be exactly the
appVersion the node reports in `/info`, or every run is VOID. #2721 moves the best header to a tying chain, which
`sibling-fork` observes.
```
bash diffrun/register.sh ~/ergo-6.0.8.jar 6.0.8
bash diffrun/run.sh diffrun/scenarios/sibling-fork-smoke.json --base ~/ergo-6.0.8.jar --candidate "$CAND" --out ~/sf-2721
```

## Lead scenarios

| scenario | nodes | question | related upstream |
|---|---|---|---|
| `fork-convergence` | 4 | does a follower on a lighter, static fork switch when it meets a peer on a heavier fork? | ergoplatform/ergo#2511 (closed), #2649 (in v6.0.8), #2721 |
| `sibling-fork` | 4 | does a node's best full block ever sit on a different fork from its best header at the same height? | ergoplatform/ergo#525, #2313 (closed), #2721 |
| `interop` | 2 | do the release and the candidate, on one network, each follow the other's mined chain to the same state root? | agreement check |
| `txload` | 2 | are real wallet payments accepted, confirmed and counted in blocks? | agreement check |
| `bootstrap-modes` | 3 | do a digest-mode follower and a pruning follower settle on the miner's chain and state root? | agreement check |

These are the lead and agreement scenarios; the full catalog (indexer, wallet, crash consistency, storage rent, the
relay floor, NiPoPoW, the Matrix line and more) is in `diffrun/README.md`. `fork-convergence` and `sibling-fork` run
empty-block devnets, so they observe header and block-section behavior only; `txload` covers the payment path.

## Where this is going

In the tree: a scenario template on the rig (`diffrun/scenarios/lib/rig-scenario.sh`, used by every scenario except
`fork-convergence`, `sibling-fork` and `wallet-oracle`), a release-candidate check on hosted runners
(`docs/release-check.md`), A/A calibration on hosted runners (`aa.yml`) and on one host
(`diffrun/examples/fork-convergence-aa-6.0.6/`), `rig/preflight.sh`, and the review frame (`review/`, including a
revert check for a PR's new tests, `review/revert-check.sh`, and a picker that builds on each PR's own merge base,
`review/pick.sh`). Reviews made with it are posted on ergoplatform/ergo pull requests: a GitHub search for "peeryard" in
that repository's PR comments returned 82 pull requests on 2026-11-26. Still planned: the two lead scenarios
(`fork-convergence`, `sibling-fork`) moved onto the rig so its oracles apply to them; scenarios built from open field
reports; and, once the maintainers have been asked, a driver that turns review requests into these runs. The rest is in
`ROADMAP.md`.

## Credit, license and security

The code, documentation and witnessed runs in this repository were produced by Claude (Anthropic; models Claude
Fable 5.1 and Claude Opus 5.5) working under a human maintainer's direction and review; the pre-publication reviews
were run by separate Claude instances and by two outside models, and their findings applied before release. The
patches of ours under `patches/` are the upstream commits as exported, with their author and co-author trailers.

CC0 1.0 Universal (`LICENSE`) for peeryard's own files. The patches under `regression/`, `patches/ergo/` and
`patches/ergo-matrix/` are derived from ergoplatform/ergo's code, which is also CC0 1.0 Universal; `patches/arkadianet/`
derives from arkadianet/ergo (Apache-2.0) and `patches/ergo-node-rust/` from mwaddip/ergo-node-rust (MIT), and those
diffs stay under their projects' licenses. Found a vulnerability? Report it privately to the project concerned; see
`SECURITY.md`.
