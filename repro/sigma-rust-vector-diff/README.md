# sigma-rust vector diff

What does one change to sigma-rust do to its results on a public conformance suite? This directory runs
[SANTA](https://github.com/mwaddip/santa) (MIT; conformance vectors blessed by the JVM reference, sigma-state) over
`ergoplatform/sigma-rust` at a base commit and at the base plus one change, and lists per change which vector entries
it fixes, which it regresses, and which change their outcome without changing pass/fail. The run is on GitHub-hosted
runners (`.github/workflows/sigma-rust-vector-diff.yml`) so that anyone can re-run it. It is not a node scenario and
needs no rig. It adds a Rust toolchain, which is what the library under test is written in.

## Pinned versions (the workflow's defaults)

| what | pin |
|---|---|
| sigma-rust base | `688511dff3e3436dfdd6bd368e3eeef6f67d59e9` (`develop`) |
| changes | `pick:57570dfe246f546015a67e418b86d9d6105ce9f7 pr:847 merge:cafebedouin/sigma-rust@1fb216b0dfb26e059ede5290e97888f27659de61 noop` (the first run on this branch used `pr:884 pr:874 pr:873 pr:870 noop`) |
| SANTA (vectors and comparator) | `mwaddip/santa` at `1820b01971901af93c7ca39e213f51860831848d` |
| runner | `mwaddip/santa-blitzen` (SANTA's sigma-rust runner, branch `develop`) at `912c34c792ebc8534918bad74c0d375559295515` |
| runner toolchain | Rust from the runner's `mise.toml` (1.92.0 at the pin), installed with `rustup --profile minimal` |
| comparator toolchain | Rust from SANTA's `tools/mise.toml` (1.92.0 at the pin); crate versions from `santa-grade/Cargo.lock`, which carries SANTA's `tools/Cargo.lock` versions (`serde_json` 1.0.150), built with `--locked` |
| runners | `ubuntu-24.04` |

A change is one of:
- `pr:<N>`: `refs/pull/<N>/head` of `ergoplatform/sigma-rust`, merged onto the base (`git merge --no-edit`);
- `merge:<owner>/<repo>@<sha>`: that commit fetched from that GitHub repository (a fork branch holding several
  changes together) and merged onto the base;
- `pick:<sha>`: that commit cherry-picked onto the base (it must be fetchable from `ergoplatform/sigma-rust`: a
  branch, tag or pull request head);
- `noop`: the base again. It is a control: built and emitted in its own job, it must show no fixed and no regressed
  entry.

## Jobs

- `plan` checks the inputs and turns the change list into the build matrix (`plan.sh`; at most 12 changes, each
  listed once). The base is always the first label; labels are `base`, `pr<N>`, `pick-<first 12 hex>`, `noop`.
- `build`, one job per label (`build_label.sh`): clones sigma-rust at the base and applies the change, clones the
  runner and SANTA at their pins as siblings (`<work>/sigma-rust`, `<work>/blitzen`, `<work>/santa`, so the runner's
  `path = "../sigma-rust/<crate>"` dependencies resolve to the change's tree), applies the runner's lenient-parse patch
  to the sigma-rust tree, runs `cargo build --release` of the runner, then the runner's `emit <vectors-dir> <out-dir>`
  once per leaf directory (it reads one directory level): `eval/v5/authored`, `eval/v5/spec`, `eval/v6/authored`,
  `eval/v6/captured`, `eval/v6/spec`, `wire/v5/authored`, `wire/v5/vendored`, `wire/v6/authored`. It uploads the
  actuals, the logs, the runner's resolved `Cargo.lock` and `manifest.json`: the change, the PR head sha, sigma-rust
  HEAD after the change and its diff stat against the base, the runner and SANTA commits, the patch's sha256, `rustc`
  and `cargo` versions, the `Cargo.lock` and binary sha256, and per leaf the emit exit status and file counts. A merge
  or cherry-pick conflict, a patch that does not apply, a failed build or an emit that writes fewer files than there
  are vector files stops the job with an error annotation; the manifest records the status (`merge-conflict`,
  `pick-conflict`, `patch-failed`, `build-failed`, `emit-failed`, `fetch-failed`) and, for a conflict, the files.
- `compare` builds the grader (`build_grader.sh`, below), grades every label and compares each change with the base
  (`compare.sh`), writes the tables to the job summary, uploads `vector-diff.json` and `summary.md`, then runs the
  grader's self-test (`grader_selftest.py`) on the base actuals.

Default list: 8 jobs (plan, six builds, compare). The build jobs have no cache: each is a cold release build of the
runner and the sigma-rust crates it depends on, expected at about 6-9 minutes; the whole run about 40-60
runner-minutes and about 10 minutes of wall time.

## How grading is done

Every entry is graded with SANTA's own comparator, the `santa-check` library (`tools/santa-check/src/lib.rs` in
the SANTA checkout), not with an equality rule of this directory. `santa-grade/` is a small Rust binary that depends
on that library by path (`build_grader.sh` links the pinned SANTA checkout in a scratch copy of the crate) and does
what SANTA's orchestrator does with a runner's actuals (`tools/conform/src/main.rs`, functions `run_one` and
`tally`):
- it dispatches on the vector file's `schema` (`santa-wire/` to `grade_wire`, `santa-transaction/` to
  `grade_transaction`, and so on; eval vectors to `grade`);
- an absent actuals file reads as `{}` and an absent entry as null, which the comparator grades as coal;
- the cost claim comes from the runner's `runner.json` (`"cost": false` at the pinned runner, so cost is not
  graded: runner-contract section 6, `docs/contract/runner-contract.md`);
- an entry fails when any dimension that `tally` records in a slice's `red` list is coal (value, cost, reject,
  roundtrip, panicked, not-implemented, and the other tiers' dimensions). With `cost: false` that is one red
  dimension per failing entry, so the per-leaf failing count equals the length of SANTA's `red` list for the slice,
  the number the scoreboard shows.

Per change, comparing each entry with the base:
- **fixed**: failing on the base, passing with the change;
- **regressed**: passing on the base, failing with the change;
- **verdict changed, same pass/fail**: the comparator's verdict object differs but pass/fail does not, for example an
  `errored` actual that becomes `panicked` (both coal);
- **output changed, same verdict**: the verdict is the same and the actual differs (compared with santa-check's
  `structural_equal`).

The summary groups them by leaf and vector file and lists the entries (up to 200 per class and change; all of them
in `vector-diff.json`, with both actuals and both verdicts).

## Controls

The compare job fails when a control fails:
- `noop` shows any fixed or regressed entry (its verdict-changed and output-changed counts are printed too; a
  nonzero count there would mean the runner's output is not reproducible between two builds of the same tree);
- the base's failing entries on a leaf differ from the expected count. The defaults are SANTA's public scoreboard
  numbers for `blitzen-develop` at the default base commit: `eval/v5/authored` 62, `eval/v5/spec` 4,
  `eval/v6/authored` 301, `eval/v6/captured` 62, `eval/v6/spec` 15, `wire/v5/authored` 11, `wire/v6/authored` 429
  (`wire/v5/vendored` is green there and is not checked). The table prints the computed and expected numbers side by
  side. With another base, give its numbers in `expected_base_failing` or `none` to skip the check;
- the base was not built, or the base is missing actuals files.

A change that does not merge, or whose build fails, is reported as "not built" in the table; its build job is red,
and the compare job fails on it only when it is a control.

`grader_selftest.py` checks the grader itself on the base actuals: in a scratch copy it plants one passing entry made
to panic, one failing entry given its blessed expected outcome, one failing `errored` entry made to panic, and one
passing entry with a changed `cost` field, and requires the grader to report exactly those four entries as regressed,
fixed, verdict changed and output changed, with exit 1 for the planted copy as a control; it also requires exit 1
for an expected count off by one, and exit 0 for an unchanged copy with the base's own counts.

## Re-run with another change list

From the Actions tab (once the workflow is on the default branch): run `sigma-rust vector diff` with, for example,
`changes` = `pr:884 pick:57570dfe246f546015a67e418b86d9d6105ce9f7 noop`. Before that, or from a fork, push the
workflow to `ci/sigma-rust-vector-diff`; a push runs the default inputs.

Locally (Linux, git, jq, rustup, python3; a build per label, several minutes each):
```
D=repro/sigma-rust-vector-diff; W=$(mktemp -d)
export SIGMA_RUST_BASE=688511dff3e3436dfdd6bd368e3eeef6f67d59e9 SANTA_COMMIT=1820b01971901af93c7ca39e213f51860831848d \
  RUNNER_COMMIT=912c34c792ebc8534918bad74c0d375559295515 INSTALL_RUST_TOOLCHAIN=1 \
  LEAVES='eval/v5/authored eval/v5/spec eval/v6/authored eval/v6/captured eval/v6/spec wire/v5/authored wire/v5/vendored wire/v6/authored'
for x in base:base pr884:pr:884 noop:noop; do
  bash $D/build_label.sh "$W/w-${x%%:*}" "$W/labels/${x%%:*}" "${x%%:*}" "${x#*:}"
done
G=$(RUSTUP_TOOLCHAIN=1.92.0 bash $D/build_grader.sh "$W/w-base/santa" "$W/grader" | tail -1)
LABEL_PREFIX= LABELS='base pr884 noop' CONTROLS=noop \
  EXPECTED_BASE_FAILING='eval/v5/authored=62 eval/v5/spec=4 eval/v6/authored=301 eval/v6/captured=62 eval/v6/spec=15 wire/v5/authored=11 wire/v6/authored=429' \
  bash $D/compare.sh "$G" "$W/w-base/santa" "$W/w-base/blitzen/runner.json" "$W/labels" "$W/out"
python3 -I $D/grader_selftest.py "$G" "$W/w-base/santa/vectors" "$W/w-base/blitzen/runner.json" "$W/labels/base" \
  "$W/selftest" $LEAVES
```

## What is and is not shown

Shown: per entry of the eight eval and wire leaf directories, whether sigma-rust with the change agrees with the
JVM-blessed expected outcome, against the base, as graded by SANTA's comparator.

Not shown:
- cost: the pinned runner declares `"cost": false` (it reads no JIT cost on `develop`), so cost is not graded;
- the transaction tier and the other SANTA tiers (the runner also mounts `transaction`; only the eight leaf
  directories above are run);
- the changes' own test suites, or anything outside what the vectors exercise;
- the change alone: each change is measured merged onto (or cherry-picked onto) the base, so a change whose branch
  is behind the base is measured with the base's other commits included, as the merge would land;
- an unpatched sigma-rust: the runner applies a declared patch to the sigma-rust tree at build time
  (`patches/sigma-rust-lenient-parse-body.patch` in the runner, sha256 recorded in each manifest). The runner's README
  describes it: it adds a parse entry that accepts a non-`SigmaProp` root (the vectors' roots are typed values) and a
  thread-local flag that only that entry sets; the one root-type check in the tree-body parse reads it. A change that
  edits the same lines makes the patch fail, and the label is reported as `patch-failed`.

The runner's committed `Cargo.lock` names the sigma-rust crate versions of an earlier release, so `cargo build`
rewrites those entries and resolves any dependency the change's tree adds at build time; each label uploads the
resolved `Cargo.lock` and the manifest records its sha256.
