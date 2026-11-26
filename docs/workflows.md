# GitHub workflows

The 17 files in `.github/workflows/`, grouped by what they are for, with each one's trigger, main inputs and the size of
one dispatch. Everything here is read from the workflow files themselves; where a file does not say, the entry says so.

## Before dispatching anything

GitHub's free Actions minutes for public repositories are subject to a usage check that can switch a repository's
workflows off, and it acts days after the fact. On 2026-10-09 it disabled the workflows of the related fork
`cafebedouin/ergo` about twelve days after one day of about 820 dispatched integration runs (about 290 runner-hours);
peeryard runs on the same account (`CLAUDE.md`). So:

- **Size every batch before sending it**: runs x jobs per run x minutes per job, and say the number. The sizes below
  give the jobs and the limits per job to do it with.
- **Keep to tens of runs a day.** A large counted batch is spread over several days, not sent at once.
- **20 concurrent jobs** are shared by every repository on the account. A wide matrix here (an A/A, a 20-shard
  `pr-scenario`) can hold all of them and queue every other repository's runs until it drains; a sweep holds half.
- **HTTP 422 "Actions has been disabled for this repository"** on a dispatch, while the permissions API still reports
  Actions as enabled, is the usage check, not a rate limit: read the banner on the repository's Actions tab. Turning
  Actions back on is the operator's decision.
- Two workflows start work on their own: `release-watch.yml` dispatches `aa.yml` (ten 150-minute jobs) when a new ergo
  release appears, and `checks.yml` runs on every push and pull request. Pushes to the `ci/*` branches named below
  start full runs of `aa.yml`, `sweep.yml`, `wallet-oracle.yml` and `indexer-bench.yml`.

**How the sizes are given.** Each "upper bound" is the sum of the `timeout-minutes` of the jobs one dispatch creates,
at the default inputs unless stated. It is a ceiling, not a forecast: most jobs end well before their limit (the
smoke dispatch in `docs/release-check.md` is four jobs and about 25 minutes). Small bookkeeping jobs that set no
`timeout-minutes` (the `pool`, `summary`, `list`, `plan`, `judge` and `deploy` jobs noted below) are left out of the
sums; without a `timeout-minutes` GitHub applies its own default limit [UNVERIFIED: the value is GitHub's, not in this
repository]. All jobs run on `ubuntu-24.04`.

**The sizes, generated.** The table below is written by `python3 ci/workflow-sizes.py --write` from the workflow files
(each job's `timeout-minutes`, its matrix at the dispatch defaults, `max-parallel`), and `checks.yml` fails when it is
stale (`--check`). A matrix built at run time is named in the bound (`examples`, `builds`, `arms`, `specs`, the
`run_minutes` a job computes): the entries below say what those come to. "Largest" puts each dynamic count at the top of
its input's documented range, and at a cap an input description states ("arms x repeats is at most 12").

<!-- sizes:begin -->
| workflow | jobs: timeout-minutes x jobs at the defaults | max-parallel | upper bound at the defaults, min | largest: input ranges and caps, min |
|---|---|---|---|---|
| `aa.yml` | build 120 x 0 (skipped at the defaults); aa 150 x 10; pool none | - | 1,500 | same |
| `checks.yml` | no-node 20 | - | 20 | same |
| `health-recheck.yml` | health 20 | - | 20 | same |
| `indexer-bench.yml` | bench 150 | - | 150 | same |
| `it-loop.yml` | loop 150 | - | 150 | same |
| `matrix-relay.yml` | build 120; run 60 x 12; pool none | - | 840 | same |
| `patch-compare.yml` | build 120; run 60 x 10 x builds (build dynamic; repeat: input repeats, default 5, 1-10); pool none | - | 120 + 60 x 10 x builds | 120 + 60 x 20 x builds |
| `pr-scenario.yml` | build 120; run run_minutes x 5 (shard: input shards, default 5, 1-20); pool none | - | 120 + run_minutes x 5 | 120 + run_minutes x 20 |
| `queue.yml` | build 30; deploy none | - | 30 | same |
| `ref-specs.yml` | plan 5; arm 110 x arms (arm dynamic; repeat: input repeats, default 1, 1-3; at most 12 jobs); table 5 | - | 10 + 110 x arms | 1,330 |
| `release-check.yml` | plan 15; build 120; example minutes x examples (include dynamic) (if); rate minutes x shards (include dynamic) (if); summary 10 | example 20 | 145 + minutes x examples + minutes x shards | same |
| `release-watch.yml` | watch 20 | - | 20 | same |
| `repro-script.yml` | run 60 | - | 60 | same |
| `spec-compare.yml` | plan none; spec 120 x 2 x arms x specs (patch dynamic; spec dynamic; repeat: input repeats, default 2, 1-5; at most 12 jobs); judge none x 0 (skipped at the defaults) | - | 120 x 2 x arms x specs | 1,440 |
| `spec-loop.yml` | loop 150 | - | 150 | same |
| `sweep.yml` | build 120; example 60 x examples (example dynamic; repeat: input repeats, default 1, 1-99); diffrun 60 x 2 (repeat: input repeats, default 1, 1-99); summary none | example 10 | 240 + 60 x examples | 12,000 + 60 x 99 x examples |
| `wallet-oracle.yml` | list none; run 40 x 9 (repeat: input repeats, default 1, 1-5); summary none | - | 360 | 1,800 |
<!-- sizes:end -->

## Checks on push

### `checks.yml`
- **Does**: the no-node checks: `shellcheck -x` on every bash script (and `-s bash` on the sourced hooks), `bash -n`,
  the Python unit tests under `tests/`, `tests/leakcheck.sh`, the shell self-tests (`lint`, `precheck`, `sequential`,
  `phases`, `indexer_diff`, `crash_consistency`, `wallet_oracle`, `wallet_workload`, `pr_path`, `tooling`), and
  `ci/export-workflows.sh --check`, and `ci/workflow-sizes.py --check` (the size table below). No node, no JDK 8. The script lists for `shellcheck` and `bash -n` are
  NUL-separated (a path with a space stays one path), and an empty list fails the step instead of passing it.
- **Trigger**: push (any branch), pull request, dispatch. **Inputs**: none.
- **Size**: one job, `timeout-minutes: 20`. A push to a branch with an open pull request in this repository triggers it
  twice (push and pull_request).
- **Covered by**: `CONTRIBUTING.md` ("Before a pull request"), which its header says the step list must equal, and
  `docs/running.md` (*Self-tests*).

## Review and verdict workflows

### `pr-scenario.yml`
- **Does**: one diffrun scenario before and after an ergoplatform/ergo pull request. The build job builds both jars
  from one base commit with `diffrun/build.sh` (the base, and the base plus the PR's production diff); `shards` runners
  each run `pairs` counterbalanced pairs; `diffrun/pool.sh` judges the pooled runs once. Variants: `aa=true` (base jar in
  both roles), `test_patches` (applied to both arms), `extra_patch` (candidate only; with `pr` empty, patch mode),
  `scenario=rig-example` (any one-jar rig example of `rig/examples/suite.tsv`, named in `scenario_env`).
- **Trigger**: dispatch. **Inputs**: `pr`, `head` (40 hex; the run fails if the PR has moved), `line` (`matrix`,
  `matrix-stack`, a release tag, or a commit; default `v6.0.8`), `scenario` (default `matrix-paychain`), `shards` (1-20,
  default 5), `pairs` (1-99, default 1), `aa`, `scenario_env`, `v4`, `test_patches`, `extra_patch`. `review/pr-line.sh
  --pr N` prints the line and the dispatch command.
- **Size**: build 120 min, then one job per shard whose limit the build job computes from the manifest:
  `floor(2 x pairs x (timeout_seconds (default 900) + precheck_timeout_seconds (default 300) when there is a precheck) / 60) + 30`
  (`pr-scenario.yml:121`). At the defaults (`matrix-paychain.json` has `timeout_seconds` 1500, no precheck) that is 80
  min per shard, so the upper bound is 120 + 5 x 80 = 520 min (about 8.7 runner-hours). At 20 shards it holds all 20
  concurrent jobs. The `pool` job sets no limit; it writes its summary and then exits with `pool.sh`'s status (before
  2026-11-26 a failing `pool.sh` ended the step under `bash -e` before the summary line was written).
- **Covered by**: `diffrun/README.md`, `diffrun/scenarios/FIT.md`, `docs/release-check.md` (through
  `review/release-check.sh`), `rig/README.md`, and the scenario docs that dispatch it (`rig/WALLET-ORACLE.md`,
  `rig/CRASH-CONSISTENCY.md`, `rig/INDEXER-DIFF.md`, `rig/WALLET-WORKLOAD.md`, `docs/storage-rent.md`,
  `patches/test/README.md`).

### `repro-script.yml`
- **Does**: runs one `repro/<dir>/run.sh` on a runner with Temurin JDK 8 and sbt, prints `sha256sum repro/<dir>/*`, and
  keeps the output as the artifact `repro-<dir>`. The script decides the verdict: it must end with a VERDICT line and
  exit non-zero when its claim does not hold (header, lines 1-2).
- **Trigger**: dispatch. **Inputs**: `dir` (must match `^[a-z0-9][a-z0-9-]*$` and hold a `run.sh`).
- **Size**: one job, 60 min.
- **Covered by**: `repro/README.md`.

### `health-recheck.yml`
- **Does**: downloads the artifacts of an earlier run in this repository and runs `diag/health.py` on each run
  directory (process exits, OutOfMemoryError, JVM fatal errors, restart loops), plus `diag/compare_pool.py` when the
  artifacts are a patch-compare layout. Changes nothing.
- **Trigger**: dispatch. **Inputs**: `run_id` (digits), `pattern` (artifact glob, default `run-*`).
- **Size**: one job, 20 min.
- **Covered by**: `diag/README.md`; fixtures in `tests/fixtures/health/README.md`.

## Calibration and sweeps

### `aa.yml`
- **Does**: the A/A calibration of `fork-convergence` and `sibling-fork`: the same jar in both roles, a fixed number of
  pairs per shard with the sequential stop rule removed, each shard its own runner; the `pool` job reports each rate with
  an exact 95% interval (`diffrun/aa_pool.py`). Exported by `ci/export-workflows.sh`. The `pool` job writes both
  pools, then fails when `aa_pool.py` refused either (no shards, a bad verdict): a missing rate is a red run, not a green
  one (`pooled.txt` is uploaded either way). The build job names the stack build that failed.
- **Trigger**: dispatch; push to `ci/aa`; dispatched by `release-watch.yml` on a new release. **Inputs**: `tag`
  (default `v6.0.8`), `sha256` (default empty: the release's own `.jar.sha256` asset), `node` (`release`, `reference`
  or `pr2721`).
- **Size**: 10 shard jobs (5 per scenario, 4 and 2 pairs) at 150 min: upper bound 1,500 min (25 runner-hours) for
  `node=release`; `reference` and `pr2721` add a 120-min build job, 1,620 min. The `pool` job sets no limit.
- **Covered by**: `diffrun/README.md` (the A/A table), `README.md`, `AGENTS.md`, `ROADMAP.md`, `docs/release-check.md`.

### `sweep.yml`
- **Does**: the publication sweep. One job builds the reference nodes from `patches/` (release line, sibling-fork set,
  Matrix; Matrix is optional), then one job per rig example and repeat runs `rig/run-suite.sh` (the list is
  `rig/examples/suite.tsv`), plus one `fork-convergence` and one `sibling-fork` pair per repeat; a `summary` job
  tabulates. Rust examples report SKIP (no binaries on the runner). Exported by `ci/export-workflows.sh`. Its first
  step, before the build, checks the inputs: `repeats` 1-99, `node` `reference` or `release`, and each name in
  `examples` a row of `rig/examples/suite.tsv`; the inputs reach the scripts through `env`, never pasted into them.
- **Trigger**: dispatch; push to `ci/sweep`. **Inputs**: `repeats` (default 1), `examples` (default all), `v4`, `node`
  (`reference` or `release`), `diffrun` (default true), `scenario_env`.
- **Size**: the workflow's own filter (`awk -F'\t' '!/^#/ && NF == 5'`) selects 50 examples from today's `suite.tsv`.
  With the defaults: build 120 + 50 x 60 + 2 x 60 = 3,240 min upper bound (54 runner-hours) at `repeats=1`; each
  extra repeat adds 3,120. The example matrix has `max-parallel: 10`, half the account's concurrency.
  Name a few examples with `examples` for anything less than a publication run.
- **Covered by**: `README.md`, `rig/README.md`, `diffrun/README.md`, `ROADMAP.md`, `docs/release-check.md`.

### `wallet-oracle.yml`
- **Does**: the wallet oracle (`rig/WALLET-ORACLE.md`) on a release jar or any jar URL: nine variants (A/A controls,
  restart, crash, rescan, fork, and two positive controls) per repeat; the `summary` job checks each variant against the
  verdict it must give (PASS, FAIL, or `-` for the fork switch, which is reported, not judged). The summary also counts
  the rows: fewer than 9 x repeats (a job that died before writing its row) fails it before the verdict check.
- **Trigger**: dispatch; push to `ci/wallet-oracle`. **Inputs**: `jar_url` (default the v6.0.7 release jar), `sha256`,
  `repeats` (1-5, default 1).
- **Size**: 9 x repeats jobs at 40 min: 360 min upper bound at the default, 1,800 at `repeats=5`. `list` and `summary`
  set no limit.
- **Covered by**: `rig/WALLET-ORACLE-REPORT.md`; the oracle itself in `rig/WALLET-ORACLE.md`.

### `matrix-relay.yml`
- **Does**: how far and how fast Matrix input blocks travel on a three-node line (A mines, B relays, C two hops away):
  the weak-blocks base and the base plus `patches/ergo-matrix/002-input-block-relay.patch` (ergoplatform/ergo#2566), each
  on `matrix-latency` at 150 +- 100 ms and at 0 ms, with the wire observer on; `diag/matrix_prop.py` pools reach, hop
  latency and duplicates.
- **Trigger**: dispatch. **Inputs**: `duration` (seconds observed per run, 30-1800, default 180; checked before the
  build, and passed to the run jobs through `env`).
- **Size**: build 120 + 12 run jobs (2 builds x 2 delays x 3 repeats, fixed) at 60 = 840 min upper bound. `pool` sets
  no limit.
- **Covered by**: `diag/README.md`.

### `patch-compare.yml`
- **Does**: compares builds of the weak-blocks line on one rig example: the base and the base plus each named patch
  alone, each at block version 3 and 4, `repeats` times; keeps rig logs, ERROR lines, gzipped node logs, per-node
  samples and `cause.json`; a `matrix-compat*` example also gets `diag/matrix_value.py`'s report. `diag/compare_pool.py`
  pools per build and version. A report, never a verdict. A build that fails (two attempts) fails the build job with
  its name, before any copy.
- **Trigger**: dispatch. **Inputs**: `patches` (default two `2597-*` candidates), `example` (default
  `matrix-relay-star`), `repeats` (1-10, default 5).
- **Size**: build 120 + (1 + number of patches) x 2 versions x repeats jobs at 60. Defaults: 3 x 2 x 5 = 30 jobs,
  1,800 + 120 = 1,920 min upper bound (32 runner-hours). `pool` sets no limit.
- **Covered by**: `diag/README.md`, `diffrun/README.md`, `patches/README.md`. `repro/matrix-uncles/uncles-compare.sh`
  dispatches this workflow 21 times, on branch `matrix-value-instr`, whose copy declares more inputs than the one on
  `main` (`compat_s`, `txload`, `extmine_poll` and others; `git show 6003c57:.github/workflows/patch-compare.yml`).

## Upstream-spec workflows

These run ergo's own test suites (or a spec copied into an ergo tree) with sbt and JDK 8 on fixed commits.

### `spec-loop.yml`
- **Does**: one ergo unit spec (or one test in it, ScalaTest `-z`) N times on one commit, each run a fresh sbt process
  with upstream CI's command line; an optional base64 patch is applied first and printed with its sha256. Counts passed,
  failed and other.
- **Trigger**: dispatch. **Inputs**: `sha` (40 hex), `spec`, `project` (`avldb`, `ergoCore`, `ergoWallet`: the root does
  not aggregate them), `filter`, `repeats` (1-30, default 10), `patch_b64`, `label` (a tracking-id-like label is
  refused).
- **Size**: one job, 150 min.
- **Covered by**: `AGENTS.md` (flaky unit specs: base and PR head, with the same delay patch), `README.md`.

### `it-loop.yml`
- **Does**: spec-loop's shape for ergo's Docker integration specs (`it:testOnly`): builds the node image once
  (`sbt docker`), then N runs each under a per-run time limit; keeps node logs only for runs that did not pass.
- **Trigger**: dispatch. **Inputs**: `sha`, `spec`, `repeats` (1-20, default 5), `run_minutes` (1-20, default 18),
  `patch_b64`, `label`.
- **Size**: one job, 150 min. The input check refuses `repeats x run_minutes` over 120, which leaves the image build
  room inside the limit; at the defaults 5 x 18 = 90 min of runs plus the image build.
- **Covered by**: no peeryard doc names it. `AGENTS.md` sends integration specs to `review/it-spec.sh` or to the ergo
  fork's `fork-ci.yml`.
- **Counting**: a run passed when sbt ran at least one test and none failed, and failed when any test failed, as in
  `spec-loop.yml`; anything else (a timeout, no `Tests:` line) is "other".

### `ref-specs.yml`
- **Does**: named ergo test classes on several trees ("arms", `name:sha[:patch]`, from any ergo repository or fork), one
  job per arm and repeat; records each patch's sha256 and the resulting git tree id; optionally one integration spec as
  upstream's `test_it` job runs it. A red test is a result; a job fails only when sbt printed no `Tests:` line. A last
  job tabulates.
- **Trigger**: dispatch. **Inputs**: `repo`, `arms` (required), `specs`, `project`, `it_spec`, `it_minutes` (5-40,
  default 25), `repeats` (1-3; arms x repeats at most 12), `label`.
- **Size**: plan 5 + arms x repeats jobs at 110 + table 5. At the cap of 12 jobs: 1,330 min upper bound; two arms once:
  230.
- **Covered by**: the patch READMEs that cite runs of it (`patches/ergo-2359/`, `ergo-2794/`, `ergo-2863/`,
  `ergo-2866/`, `ergo-2924/`); mentioned in `rig/README.md`.

### `spec-compare.yml`
- **Does**: ergo test specs on the weak-blocks line with each of several patches applied alone (the arm `base` is the
  control), each spec in its own job, `repeats` times; keeps the sbt log and the ScalaTest XML. With `judge_mutant` and
  `judge_test`, a last job prints `diag/mutation_judge.py`'s verdict (KILLED when the control passes in every job and the
  mutant fails in every job).
- **Trigger**: dispatch. **Inputs**: `patches`, `specs`, `repeats` (1-5, default 2), `matrix_base`, `judge_mutant`,
  `judge_test`, `judge_control`.
- **Size**: arms x specs x repeats jobs at 120; the plan job refuses a product over 12 (as `ref-specs.yml` caps
  arms x repeats), so the upper bound is 1,440 min. Two arms, one spec, the default two repeats is 480 min. `plan` and
  `judge` set no limit.
- **Covered by**: `patches/README.md`, `diag/README.md` (the mutation judge); mutation patches come from
  `patches/mutate.sh`.

### `indexer-bench.yml`
- **Does**: the rebuild rate of ergo's extra indexer from an empty index, per ergo ref, on one runner so the arms share a
  host: `bench/indexer/ExtraIndexerRebuildRateSpec.scala` is copied into each arm's tree, the spec's chain generator is
  edited to mint tokens only in blocks 1-3 (the same edit on every arm), and the arms run interleaved, the order reversed
  every other round. A CPU-and-write floor, not a disk-bound mainnet rate (header). The step summary lists every
  arm and round; any run that printed no result (`NO RESULT`: an exception, OOM or the 60-minute wait) then fails the job.
- **Trigger**: dispatch; push to `ci/indexer-bench` (with the `PUSH_*` values in the file). **Inputs**: `arms`
  (`label=ref`, default `v609=v6.0.9 pr2717=pull/2717/head`), `blocks` (1-4800), `rounds` (1-5, default 3).
- **Size**: one job, 150 min.
- **Covered by**: no peeryard doc names it.

## Release workflows

### `release-check.yml`
- **Does**: a release-candidate check of ergoplatform/ergo: the commits, pull requests and paths since the baseline tag
  (`ci/release-check/scope.py`), mapped to scenarios (`path-map.tsv`) plus the core set (`catalog.tsv`); the candidate is
  built from source with `ci/build-ref.sh` and the baseline is the release's own jar, checked by its `.jar.sha256`; then
  `suite` (rig examples on each jar), `upgrade` (data dir restarted on the candidate, mixed networks) and `rates`
  (diffrun scenarios pooled per role). A rate is flagged when the candidate's exact 95% interval excludes the baseline's
  point estimate. A `summary` job writes the table and a draft note. Hand-maintained.
- **Trigger**: dispatch only. **Inputs**: `candidate`, `baseline`, `scenarios` (`auto`, `core` or names), `parts`
  (default `suite,upgrade`), `repeats` (1-3), `rate_pairs` (1-40, default 12).
- **Size**: at most 30 jobs per dispatch, plan, build and summary included (`plan.py --max-jobs 30`); a plan over it is
  refused. Fixed jobs: plan 15, build 120, summary 10. Per-job limits are computed by `ci/release-check/plan.py`: an
  example job `ceil(arms x catalog timeout / 60) + 15` (`plan.py:80`), a rate shard `min(350, floor(2 x pairs x
  per-run) + 30)` (`plan.py:93`). No whole-dispatch bound is given here: it depends on the selection. A full `auto`
  check usually goes out as two dispatches, `parts=suite,upgrade` and then `parts=rates`, spaced in time.
- **Covered by**: `docs/release-check.md` (inputs, the smoke dispatch, reading the result), `review/RELEASE-CHECK.md`,
  `README.md`, `rig/README.md`.

### `release-watch.yml`
- **Does**: watches ergoplatform/ergo releases. For a new non-prerelease tag with no `aa.yml` run here yet: runs
  `patches/check.sh` against it (NEEDED / CONTAINED / COLLIDES), opens an issue when the stack needs an edit, and
  dispatches `aa.yml` on the new tag. Opens an issue once when that release's A/A run failed, and does not retry it.
  The release tag must look like one (`^v[0-9][0-9A-Za-z.+-]*$`) before it is used; it and `force` reach the steps
  through `env`.
- **Trigger**: schedule (`41 5 * * *`, daily 05:41 UTC); dispatch. **Inputs**: `force` (dispatch the A/A even if the
  release already has a run).
- **Size**: one job, 20 min; on a new release it also starts an `aa.yml` run at `node=release` (1,500 min upper bound,
  above) without anyone dispatching it.
- **Covered by**: `docs/release-check.md`, `diffrun/README.md`, `patches/README.md`.

## Queue and site

### `queue.yml`
- **Does**: renders the review-queue pages (cafebedouin.github.io/peeryard and `/maintainers`) from public GitHub data
  with `queue/build.py` under `queue/rules.json`, reading the earlier daily snapshots back from the published site first,
  and deploys them to GitHub Pages. No node runs. A review counts as made at the current head by its `commit_id`; a
  comment by its time against the head's push time (`head_at_source` in `docs/queue-data.md`). A GitHub search that
  fails (the outcomes view) is a warning in the build log.
- **Trigger**: schedule (`17 6 * * *`, daily 06:17 UTC); dispatch; push to `main` touching `queue/**`,
  `patches/**/patches.json` or the workflow. **Inputs**: none.
- **Size**: build 30 min; the `deploy` job sets no limit.
- **Covered by**: `docs/queue-data.md`.

## `ci/`

Not workflows themselves: the scripts some workflows call, and example workflow files to copy.

- `ci/export-workflows.sh`: writes `sweep.yml` and `aa.yml` from their copies in the repository peeryard is developed in
  (`../.github/workflows/peeryard-{sweep,aa}.yml`, where the tree sits under `peeryard/`); `--check` exits 1 when the
  exported files are stale, and `checks.yml` runs it; its temporary file is removed on every exit. In a standalone clone there is no source directory and it does
  nothing; the exported files are then the source (their headers say "if this repository is the source, edit here").
- `ci/lib.sh`: shell helpers the workflows source after their checkout (`source ci/lib.sh`, or `peeryard/ci/lib.sh`
  where peeryard is checked out under `peeryard/`): `build` and `stack` (`diffrun/build.sh` and `patches/stack.sh` with
  one retry), `need_jar` (a jar checked before it is copied, under its own `::error::` line) and `is_idlike` (a label
  that reads as a private tracking id). Used by `aa`, `sweep`, `patch-compare`, `matrix-relay`, `pr-scenario`,
  `it-loop`, `spec-loop`, `ref-specs` and `indexer-bench`.
- `ci/workflow-sizes.py`: the size table above, from the workflow files (standard library; a reader for the YAML
  subset they use); `--write` updates this file, `--check` exits 1 when it is stale (`checks.yml` runs it).
- `ci/build-ref.sh`: the build step of a hosted workflow for any ergo ref (commit, branch or tag), through
  `diffrun/build.sh <commit>` with one retry, after publishing the sigma-state snapshot the commit pins, if any. Used by
  `release-check.yml`.
- `ci/release-check/`: the planner and reporter of `release-check.yml` (`scope.py`, `plan.py`, `report.py`) and its
  tables (`catalog.tsv`, `path-map.tsv`, `extra-suite.tsv`, `recorded-rates.json`). `scope.py --api` counts the
  `gh api` lookups that failed (`api_errors` in `scope.json`, a warning, and a line in `scope.md`) instead of reading
  them as "no pull request"; `plan.py` refuses a malformed catalog `rate` column by name.
- Four `.example` workflows, inert until copied into `.github/workflows/` (described in `diffrun/README.md`):
  - `diffrun.yml.example`: a dispatch-only differential workflow over public-tier manifests that uploads only each run's
    `verdict.json` and `table.txt`; its header says it is untested on hosted runners. One job, 300 min.
  - `diffrun-hosted.yml.example`: the full public-tier diffrun on a hosted runner, the variant that has been run (header);
    in PR mode the base is the upstream release jar, so the pair differs in toolchain too. One job, 350 min.
  - `diffrun-external.yml.example`: the same for a repository that does not vendor peeryard (two checkouts, peeryard at
    a pinned commit); untested as a whole (header). One job, no `timeout-minutes`.
  - `release-watch.yml.example`: polls ergo releases every six hours (`17 */6 * * *`) and dispatches
    `diffrun-hosted.yml` release-vs-release; it needs that example installed and write permission (it commits
    `state/`). The `release-watch.yml` that runs here is a different, hand-maintained workflow that dispatches `aa.yml`.
