# peeryard

**Status: EXPERIMENTAL (alpha).** peeryard exists so that a reviewer who cannot read the node's language can still
execute its claims. Its author is not a Scala programmer. Every review made with it says which of its statements were
executed and which were read, and every number in it can be re-run from the command that produced it. That is the
whole idea: the node is tested as a **network** on one Linux machine, with no root and no Docker (several real node
processes, one network namespace each, links you can delay, drop, partition and heal, nodes you can crash and revive,
different versions and implementations side by side, real transactions in the blocks), and a pull request gets a
before/after measurement to read next to its code instead of an opinion.

**Who it is for.**
- Ergo node maintainers: not to run, unless you want to. What reaches you is the output: an issue with a reproduction,
  a pull request whose test fails on the release and passes with the fix, a review that says what was executed. The
  `regression/` track is the one part meant for your own tree: link shaping inside `src/it`, no image change.
- Contributors with open pull requests: a before/after on your own change, built on its merge base, with the release's
  own base rate beside it (`review/`, `diffrun/`).
- Anyone who wants to help with node development and does not know where to start: `AGENTS.md` and `review/` are a
  procedure, not a skill. A laptop, a model and a public pull request produce a review a maintainer can act on, in a
  form that stays the same whoever runs it.
- Models: an agent asked to review a pull request starts at `AGENTS.md`; a person starts at the quick start below.

**Review queue:** [cafebedouin.github.io/peeryard](https://cafebedouin.github.io/peeryard/) lists the open ergoplatform/ergo
pull requests that need a review, ranked by public rules (`queue/rules.json`), and
[`/maintainers`](https://cafebedouin.github.io/peeryard/maintainers/) the ones waiting on a maintainer, opening with the
PRs this test suite depends on. Generated daily from public GitHub data; a disagreement with a rank is a pull request
against the rules.

**What it is not.** peeryard checks whether a change does what it says and whether it holds under bad network
conditions. It does not judge whether a change is the right design, and it has nothing to say about cryptography or
protocol choices; those stay with the maintainers. A verdict is evidence, not proof, and it is noisy: in an A/A
calibration on GitHub-hosted runners, the unchanged 6.0.6 release failed to switch forks in 17 of 40
`fork-convergence` runs (8 of 16 on a development host), and the shipped decision rule for that scenario gives a false `SUPPORTS` in about 13% of
cases when the release switches 85% of the time (`diffrun/README.md`). Read a verdict with those rates beside it.
Many node defects only appear with several nodes and imperfect links (forks that never resolve, followers that never
switch to the heavier chain, sync that stalls after a reorg); they are hard to reproduce on one machine and flaky in
CI, and peeryard makes them runnable and repeatable on a network that can mix the Scala node, the two Rust nodes and
the Matrix line. It is a lab for a reviewer, not a replacement for one.

The name is meant like a railyard or a shipyard: a place where the vessels, here peers, are brought in, marshalled,
split and rejoined, inspected, repaired and sent back out.

**What runs today**
- `rig/` — N nodes, shaped links, mining control, mixed versions, wallet payments, long runs; examples that check
  the rig itself; `rig/devnet.sh` keeps a devnet up across sessions, its chain kept across `down` and `up`.
  Every run records the network it actually ran (`effective.json`).
- `diffrun/` — the scenario runner: build a candidate jar from a git ref, a patch, or part of a pull request
  (hunk isolation by file), run a scenario N paired times, get `SUPPORTS` / `AGAINST` / `NULL` / `DEGENERATE`.
  Five node scenarios ship (`fork-convergence`, `sibling-fork`, `interop`, `txload`, `bootstrap-modes`); the
  first two reproduce behavior that is public in upstream issues or PRs, the other three check agreement.
- `regression/` — the same link shaping inside ergo's own Docker integration suite (a sidecar with `NET_ADMIN`,
  node image untouched), with three example specs and a failure classifier, as a patch on v6.0.6 meant to become
  upstream pull requests.
- `stack/` — a companion for the review queue: which open PRs share text and which one to land first. Git
  only; triage, not authority (see its README's Known issue).
- `patches/` — node fixes peeryard carries until they land upstream (ours and adopted PRs; nine open-PR patches on
  6.0.6 today, eight in the default stack), the reference node built from the release plus those patches, and a check that flags a patch a new
  release has made redundant. A pull-request review builds both jars on the PR's own merge base, never on this stack.
- `ROADMAP.md` — what is covered by layer, what is planned next, the scenario backlog, and what is out of scope.
- `review/` — reviewing a pull request with all of the above: pick a PR, run the recipes that fit it, write the
  report in the house form (`review/GUIDE.md`, templates by kind), three reviews of the draft, four gates
  (`review/GATES.md`), and a human who posts. `AGENTS.md` and `.claude/skills/review-pr` drive it for an agent.
- `.github/workflows/` — the same suite on GitHub-hosted runners: `sweep.yml` (every rig example, and one pair each of
  `fork-convergence` and `sibling-fork`, on the reference nodes) and `aa.yml` (the A/A calibration of those two); the
  runs a published verdict is meant to rest on.
- `audits/` — where a run's evidence lives (ignored by git except the layout and an example), so a reviewer
  can answer follow-up questions from what actually ran.

A verdict is **evidence, not proof**: it summarizes N runs of one scenario on one machine. Read the known limits
in each component's README before citing one.

## Scope

peeryard creates **ordinary network conditions for honest nodes**: delay, loss, partition and heal, crashes and
restarts, mining control, wallet payments, and different node versions side by side. It contains no attack
tooling: no crafted or malformed messages, no fuzzer, no misbehaving peers. Its scenarios reproduce node
behavior that is already public.

## Two tracks

| | `rig/` + `diffrun/`: **local** | `regression/`: **upstream regression** |
|---|---|---|
| for | exploring, reproducing, before/after checks of a PR on your own machine | turning a reproduction into a test the ergo maintainers can merge and run in CI |
| runs | real node jars, one network namespace per node, no Docker, no root | ergo's own Docker integration suite (`src/it`), sbt, JDK 8 |
| link shaping | `netem` applied directly (the rig owns its namespaces) | a **sidecar** container with `NET_ADMIN` in the node's namespace; node image and containers untouched |
| output | a verdict (`SUPPORTS` / `AGAINST` / `NULL` / `DEGENERATE`) over N paired runs | a ScalaTest spec that passes or fails, with a named failure cause |

## Quick start (local)
All commands below run from the root of a peeryard clone:
```
git clone https://github.com/cafebedouin/peeryard && cd peeryard
```

**Host setup, once.** Installing the packages and two commands need `sudo`; nothing else in peeryard does.
```
sudo apt-get install -y jq iproute2 util-linux procps coreutils curl unzip git python3 default-jre-headless   # Debian/Ubuntu names
sudo apt-get install -y openjdk-8-jdk   # only to build candidate jars; sbt too: https://www.scala-sbt.org/download
sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0   # Ubuntu 23.10+ only; see below
sudo modprobe sch_netem
unshare -Urmn true && echo "user namespaces ok"
bash rig/preflight.sh
```
The sysctl exists only on Ubuntu kernels (23.10 and later). It turns off, for **every program on the host**, the
AppArmor rule that stops unprivileged programs from creating user namespaces; that rule is a hardening measure
that narrows the kernel code a local unprivileged process can reach. Setting it to 0 gives that hardening up
until the next reboot, when the value resets to 1 (it is not written to `/etc/sysctl.d`). On other distributions
the key does not exist and unprivileged user namespaces are usually allowed already: if `unshare -Urmn true`
succeeds, skip the sysctl.

**The release jar and the rig.** These need only the release jar and the run card's packages (below; `rig/preflight.sh`
checks them and fails closed).
```
# the ergo-<version>.jar asset of the GitHub release (ergo v6.0.6 reports appVersion 6.0.6), and its sha256
curl -fsSL -o ~/ergo-6.0.6.jar https://github.com/ergoplatform/ergo/releases/download/v6.0.6/ergo-6.0.6.jar
echo "21b9023933b19b98b7eb4d50cb78bcb6c827a0fe65711a00ceaf1b83f8f3a323  $HOME/ergo-6.0.6.jar" | sha256sum -c

# a two-node network: A mines, B syncs; checks the rig itself (about a minute)
PEERYARD_JAR=~/ergo-6.0.6.jar bash rig/rig.sh rig/examples/bringup.json rig/examples/bringup.sh

# real transactions: A pays B from its mining rewards, the payments confirm (a minute or two)
PEERYARD_JAR=~/ergo-6.0.6.jar bash rig/rig.sh rig/examples/txload.json rig/examples/txload.sh
```
A run ends with the example's own verdict line and the rig's; for `bringup` it looks like this (heights vary):
```
  SYNC-OK: B is on A's chain at height 7 (B.h=7, A.h=27, A keeps mining)
[rig] === hook done (verdict: PASS) ===
```
The exit status says the same: 0 PASS, 1 FAIL, 3 INCONCLUSIVE. INCONCLUSIVE is not a verdict on the node: the run
could not show what the example checks, and a `[rig] CAUSE` line says why (`HARNESS` means a rig step, such as a
partition, a crash or a restart, did not happen as asked). Exit 2 or 10 means the rig could not bring the network up
(a node never answered, a link never connected, a namespace or netem step failed) before the example started; the
last `[rig]` lines say which. To run several examples and get one line each:
```
PEERYARD_JAR=~/ergo-6.0.6.jar bash rig/run-suite.sh bringup txload     # rig bringup: PASS (SYNC-OK) ...
```
With no names it runs every example in `rig/examples/suite.tsv`, skipping those whose artifacts are not set.

**A candidate jar.** Built from a clone of ergo with JDK 8 and sbt (the first build on a host downloads sbt's dependencies: 10 to 20 minutes;
later builds are cached by the diff's hash) (set `JAVA8_HOME` if JDK 8 is not found under
`/usr/lib/jvm`). The example takes the production diff of ergoplatform/ergo#2511 (`master...pr-2511`: from the
PR's merge base with master to its head) and applies it onto v6.0.6, as the hosted CI example does;
`-- <paths>` restricts the diff to those paths (hunk isolation by file). The example holds while #2511 is open; once it
merges the range is empty and `build.sh` stops, so take any open pull request instead.
```
git clone https://github.com/ergoplatform/ergo ~/src/ergo
git -C ~/src/ergo fetch origin pull/2511/head:pr-2511
CAND="$(DIFFRUN_ERGO_CLONE=~/src/ergo bash diffrun/build.sh v6.0.6 master...pr-2511 -- src/main ergo-core/src/main ergo-wallet/src/main avldb/src/main)"
echo "$CAND"          # the cached candidate jar; its sidecar <jar>.json sits beside it
```
The release jar above was built upstream and the candidate here, so a pair of them differs in two ways (the
patch and the toolchain). `diffrun/build.sh v6.0.6` with no patch builds the unpatched base with the same
toolchain, which leaves one difference. To review a pull request, build both jars on the PR's own merge base
instead (`AGENTS.md`, `review/README.md`).

**A two-version devnet that stays up**: the release jar mines, the candidate follows; query, stop, resume, wipe.
```
PEERYARD_JAR=~/ergo-6.0.6.jar PEERYARD_JAR_B="$CAND" bash rig/devnet.sh up rig/examples/mixed.json two
bash rig/devnet.sh curl B /info two           # then: status | logs B | down | up (same command) | wipe
```

**A scenario verdict**: release vs candidate. Below, one paired run of the smoke manifest (about ten minutes); a verdict
to cite comes from the full `fork-convergence.json` (8–12 pairs, 1.5–2.5 hours). The registered version must be exactly
the appVersion the node reports in `/info`, or every run is VOID.
```
bash diffrun/register.sh ~/ergo-6.0.6.jar 6.0.6
bash diffrun/run.sh diffrun/scenarios/fork-convergence-smoke.json --base ~/ergo-6.0.6.jar --candidate "$CAND" --out ~/fc-2511
```
Example output of a finished run is in `diffrun/examples/`.

**Run card.** You need:
- Linux with unprivileged user namespaces, `iproute2` with `sch_netem`, util-linux (`unshare`, `nsenter`), procps
  (`ps`, `pgrep`, `pkill`), coreutils (`timeout`, `sha256sum`, `realpath`), `jq`, `curl`, `unzip`, `git`, `python3`
  (the rig's cause classifier and the diag tools; standard library only),
  **bash 4.4 or later**, a Java runtime for the node (the example runs used OpenJDK 21);
- **JDK 8 and sbt**, only to build candidate jars (`diffrun/build.sh --dry-run` needs neither);
- the Matrix examples need the `weak-blocks` reference node (`patches/sigma-snapshot.sh` once, then
  `patches/stack.sh --build ergo-matrix`; `patches/README.md`), and the Rust examples an arkadianet or ergo-node-rust
  binary (`rig/README.md`); `rig/run-suite.sh` skips what is not set;
- about 1.5 GB of free RAM for a four-node scenario;
- **Docker is optional, two ways:** `docker/` builds an image with the whole run card (the rig runs inside it with no
  root: `docker run --security-opt seccomp=unconfined --security-opt apparmor=unconfined -v "$PWD":/peeryard peeryard`;
  witnessed: preflight and `bringup` pass inside), for hosts where unprivileged user namespaces are locked; and
  `review/it-spec.sh` runs one of ergo's own Docker integration specs on a PR's tree, the suite upstream's CI runs,
  which peeryard treats as a dependency it calls, not code it carries.

A fork-convergence run takes 3–7 minutes; a full verdict takes 8–12 paired runs, 1.5 to 2.5 hours. The timings in
this README come from a 2019 development host and 2-vCPU GitHub runners; a newer machine is faster. What gets
written, and where:
- the rig: its scratch directory (`SCRATCH`, default a fresh `mktemp -d` under `$TMPDIR` or `/tmp`, which is not
  deleted afterwards), and node logs under a topology's `log_dir` when it sets one (anywhere it names);
- `rig/devnet.sh`: `~/.peeryard/devnet/<name>` (or `PEERYARD_DEVNET_DIR`);
- `diffrun/run.sh`: its `--out` directory (default a fresh `diffrun.<scenario>.*` directory under `$TMPDIR` or `/tmp`);
- `diffrun/build.sh`: the jar cache (`DIFFRUN_CACHE`, default `~/.cache/diffrun/builds`), with the temporary build
  worktree inside it (`$DIFFRUN_CACHE/.tmp.*/wt`; git's bookkeeping for it goes in the ergo clone's `.git`), and
  a short socket directory under `/tmp` that sbt needs;
- `review/revert-check.sh`: `/tmp/revert-check.*` unless `--out` is given.

The no-node self-tests take seconds: `T=$(mktemp -d) bash tests/sequential.sh`, `T=$(mktemp -d) bash tests/lint.sh`,
`T=$(mktemp -d) bash tests/precheck.sh` and `T=$(mktemp -d) bash tests/tooling.sh`, the last on the patch check,
sidecar registration and provenance helpers. `T` must be a fresh empty directory: each test deletes it first. In a
container, see `rig/README.md` for the two security options the rig needs.

The mnemonics, the REST API key `hello` (and its hash) and the solver key in `rig/rig.sh` and the example topologies
are public devnet test values, not secrets: they unlock only the private devnets peeryard starts.

## Scenarios
| scenario | nodes | question | related upstream |
|---|---|---|---|
| `fork-convergence` | 4 | does a follower on a lighter, static fork switch when it meets a peer on a heavier fork? | ergoplatform/ergo#2511 |
| `sibling-fork` | 4 | does a node's best full block ever sit on a different fork from its best header at the same height? | ergoplatform/ergo#525, #2313 |
| `interop` | 2 | do the release and the candidate, on one network, each follow the other's mined chain to the same state root? | agreement check |
| `txload` | 2 | are real wallet payments accepted, confirmed and counted in blocks? | agreement check |
| `bootstrap-modes` | 3 | do a digest-mode follower and a pruning follower settle on the miner's chain and state root? | agreement check |

`fork-convergence` and `sibling-fork` run empty-block devnets, so they observe header and block-section behavior
only; `txload` covers the payment path. The details, the expectations and the known limits of each are in
`diffrun/README.md`.

## Where this is going
In the tree: a scenario template on the rig (`diffrun/scenarios/lib/rig-scenario.sh`, used by `interop`,
`txload` and `bootstrap-modes`), a calibration run (`diffrun/examples/fork-convergence-aa-6.0.6/`: the release's
own base rate on one host, read before any `SUPPORTS` is cited), `rig/preflight.sh`, and the review frame
(`review/`, including a revert check for a PR's new tests, `review/revert-check.sh`, and a picker that builds on
each PR's own merge base, `review/pick.sh`; the frame was used for the pilot reviews posted before the rename, the
merge-base picker is newer and unexercised on a live pull request). Still planned: the two
lead scenarios (`fork-convergence`, `sibling-fork`) moved onto the rig so its oracles apply to them; scenarios
built from open field reports; a release-candidate run before each tag; and, once the maintainers have been
asked, a driver that turns review requests into these runs.

The docs: `rig/README.md`, `diffrun/README.md`, `regression/README.md`, `stack/README.md`.

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
