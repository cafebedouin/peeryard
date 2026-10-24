# Release-candidate check (`release-check.yml`)

A check of an upcoming ergoplatform/ergo release on GitHub-hosted runners, for what upstream CI does not run: several
nodes on one network under shaped links, the upgrade from the previous release, and the rates of the two rate
scenarios against that release. It needs a candidate ref and a baseline release, nothing else. It reports results; it
does not decide anything about the release.

It complements `review/release-check.sh` (`review/RELEASE-CHECK.md`), which dispatches a fixed set of diffrun
scenarios through `pr-scenario.yml` on the previous tag plus a release PR's production diff: interop, indexer-diff,
crash-consistency, wallet-workload-plain, wallet-oracle-restart, fork-convergence-smoke, sibling-fork. This workflow
takes a ref instead of a PR and adds the rig examples, the upgrade path and the rates per role; it does not repeat the
extra-indexer, crash-consistency or wallet-workload sets.

## Run it

```
gh workflow run release-check.yml -R cafebedouin/peeryard -f candidate=v6.0.10 -f baseline=v6.0.9 -f parts=suite,upgrade
# later, once that run has finished:
gh workflow run release-check.yml -R cafebedouin/peeryard -f candidate=v6.0.10 -f baseline=v6.0.9 -f parts=rates -f rate_pairs=20
```

For the next release, change the two refs: `candidate` is the release branch (or a tag or a 40-hex commit), `baseline`
the release it follows. Start with a smoke dispatch of one cheap example (`-f scenarios=bringup -f parts=suite`, four
jobs, about 25 minutes with a cold build) to check that the candidate builds and the rig runs it.

| input | default | meaning |
|---|---|---|
| `candidate` | the newest `v6.N.N` branch of ergoplatform/ergo, by version | a branch, tag or 40-hex commit; a branch name wins over a tag of the same name (give the tag's commit to check the tag) |
| `baseline` | the latest non-prerelease | a release tag `vN.N.N` whose release has the `ergo-<version>.jar` and `ergo-<version>.jar.sha256` assets (every release since v6.0.8) |
| `scenarios` | `auto` | `auto` = the scenarios the changed paths map to, plus the core set; `core` = the core set; or names from `ci/release-check/catalog.tsv` |
| `parts` | `suite,upgrade` | any of `suite`, `upgrade`, `rates`, comma-separated |
| `repeats` | `1` | jobs per example, 1-3; candidate and baseline alternate which runs first |
| `rate_pairs` | `12` | pairs per rate scenario, 1-40, split into shards of four pairs |

The default candidate is the highest release branch by version. When two release branches are open at once (the one
being released and the next), it picks the later one: name the candidate explicitly.

Every input is checked in the `plan` job before anything is built. One dispatch is capped at **30 jobs** (plan, build
and summary included); a plan over the cap is refused with a message. A full `auto` check of a release with many
changes is usually over it, so it goes out as two dispatches, `parts=suite,upgrade` and then `parts=rates`, spaced in
time. Size a batch before dispatching (jobs x minutes): GitHub can switch a repository's Actions off after a heavy day,
with a lag. On `422 Actions has been disabled`, read the repository's Actions tab before assuming a rate limit.

## What it does

1. **Scope** (`plan` job, `ci/release-check/scope.py`). The commits in `<baseline tag>..<candidate>`, the pull requests
   they came from (subject references, the commits a merge brings in, then the GitHub API for the rest) and every path
   that differs between the two trees. Each path is mapped to scenarios by `ci/release-check/path-map.tsv` (an extended
   regular expression per row; every matching row applies). The selection is the union of those scenarios and the core
   set (`catalog.tsv`, `core` = 1), in catalog order. Paths with no scenario (tests, the extra indexer, docs) and paths
   no row matches are listed in the scope report and in the draft note. The step summary shows the scope report.
2. **Build** (`build` job). The candidate is built from source by `ci/build-ref.sh <commit>`, which runs
   `diffrun/build.sh <commit>` with one retry and the sigma-state snapshot step; the jar carries the build sidecar
   (`source_sha`, `expected_app_version`, `jar_sha256`, `stripped_jar_sha256`). The baseline is the release's own jar
   asset, refused unless its sha256 equals the release's `.jar.sha256` asset, and registered with the version the tag
   names. The two jars must report different appVersions, or no run could tell them apart. `ci/build-ref.sh` is the
   generalized build step: any workflow can build any ergo ref with it.
3. **suite**: one job per example and repeat, through `rig/run-suite.sh` (PASS = the example's marker and the rig's
   exit status 0, as in `sweep.yml`). The example runs on the candidate and, when it runs on one jar, on the baseline
   in the same job, so a red on both is visible as such. A FAIL of an example listed in `rig/examples/experimental.txt`
   is reported as `FAIL (experimental)`. The job fails only on a candidate FAIL. `loss` is not in `suite.tsv`; the
   release check adds its row, and those of the upgrade examples, from `ci/release-check/extra-suite.tsv` in its own
   checkout only.
4. **upgrade**: examples with both jars by construction, so there is no baseline-only arm:
   - `upgrade-restart`: M mines and U follows on the baseline; U has a file-backed wallet (restored over the API with a
     password) and receives payments. U is cut from M, stopped and started on the candidate over the same data
     directory. While still cut (nothing can come from a peer): U reports the candidate's version, its height and the
     header id and state root at that height are unchanged, the candidate unlocks the baseline's secret file and shows
     the same confirmed balance. Then healed: U catches up, a payment from its upgraded wallet confirms, and U settles
     with M at least 10 blocks above the height of the stop.
   - `upgrade-mixed`: B1, B2 on the baseline and C1, C2 on the candidate, each follower reachable only through a node of
     the other version. Phase 1, the baseline mines and the candidate follows (and relays to the other baseline node);
     phase 2, the candidate mines and the baseline follows; phase 3, both mine at once over a 100 ms link, so forks form
     and resolve across versions. A payment crosses in each direction. PASS needs every phase converged, both payments
     confirmed, one state root at the end with blocks of both miners on the final chain, and no ban or blacklist line.
   - `mixed` (selected by network paths): the two-node one-direction version, candidate mining and baseline following.
   Both new examples run anywhere with two jars: `PEERYARD_JAR_B=<baseline> PEERYARD_JAR=<candidate> bash rig/rig.sh
   rig/examples/upgrade-restart.json rig/examples/upgrade-restart.sh`.
5. **rates**: `fork-convergence` (`switched==true`) and `sibling-fork` (`E_total>0`, the divergence rate), the two
   scenarios `aa.yml` calibrates. Each shard runs four pairs with `diffrun/run.sh`, base = baseline and candidate =
   candidate, order counterbalanced, the stop rule removed. The summary pools the VALID runs per role and gives each
   rate an exact 95% interval (`diffrun/aa_pool.py`'s Clopper-Pearson). A rate is flagged when the candidate's interval
   does not contain the baseline's point estimate from the same dispatch. That is a difference to look at, not a
   verdict: with the baseline at 100%, a single candidate miss flags it, so a candidate whose true rate is 0.98 is
   flagged in about a third of 20-pair dispatches. Fisher's exact test (two-sided) on the two roles' counts is given
   beside the flag. The baseline's interval is also checked for overlap with the interval of the rate recorded earlier
   for that release (`ci/release-check/recorded-rates.json`, with the run that measured it), as a check that the
   workflow reproduces it.
6. **Report** (`summary` job, `ci/release-check/report.py`). The step summary gets one table (scenario, candidate
   result, baseline result or rate, links to the jobs). The artifact `release-check-a<attempt>` holds `summary.md`,
   `rates.json`, `scope.md` and `release-check.md`: a draft results note written from the artifacts, facts only,
   for a person to check against the linked jobs before any use. It says nothing about merging or release timing. A
   re-run job uploads under its attempt number; the report shows the latest attempt and lists the earlier ones.

## Reading a red

The workflow does not classify. For each red: re-run it once (a new dispatch with `scenarios=<name>` keeps the
first run's record intact), then record which it is:
- **also red on the baseline**: the same example failed on the baseline jar in its own arm: not a candidate change;
- **a known flake**: the example's failure is listed with its rate in `rig/README.md` (*Experimental examples*,
  *Seen to fail*) or in a tracked issue: cite where;
- **environmental**: the log names a runner cause (a harness failure line, a timeout before the nodes came up, a
  download error), quoted;
- **candidate only**: red on the candidate and green on the baseline in both runs: a difference to report with the
  logs (`ex-<name>-<repeat>-a<attempt>`: the rig output and the node logs of a run that did not pass).

## Limits

- **No full mainnet sync.** A hosted job has 6 hours and about 14 GB of disk; the mainnet chain does not fit in
  either. A partial sync against public peers was not added: its result would depend on the peers reached that day.
- Every scenario is a private devnet of one to four nodes, small blocks, short intervals: nothing here measures
  behaviour that needs a public network's size, load or timing.
- Upstream CI already runs the unit, wallet, core and integration tests on the candidate; this check does not.
- The Matrix (weak-blocks) line and the Rust nodes are out of scope for the release line.
- The extra indexer, crash consistency and the wallet workload are not run here; `review/release-check.sh` runs them.
- The path map is coarse (directories, a few file patterns). A path it maps to no scenario is listed, not hidden; a
  change outside every scenario's reach passes this check by construction.
- One runner class (ubuntu-24.04, 4 vCPU, 16 GB on a public repository). Rates are comparable only within that class.

## Wiring to release-watch (off)

`release-watch.yml` runs on a schedule and does not dispatch this workflow. To have it do so by hand, a step like
the one below can be added to its `watch` job, guarded by a dispatch input that a schedule never sets, so nothing
runs without a person:

```yaml
      - name: Release check of the newest release branch (by hand only)
        if: inputs.release_check == 'true'
        run: gh workflow run release-check.yml -R "$GITHUB_REPOSITORY" --ref "${GITHUB_REF_NAME}" -f parts=suite,upgrade
```

with `release_check: { description: 'also dispatch release-check.yml', default: 'false' }` under its inputs.

## Files

| file | role |
|---|---|
| `.github/workflows/release-check.yml` | the workflow (hand-maintained, not exported by `ci/export-workflows.sh`) |
| `ci/build-ref.sh` | build any ergo ref with `diffrun/build.sh` (the generalized build step) |
| `ci/release-check/catalog.tsv` | the scenarios: part, core, baseline arm, rate condition and pairs per shard |
| `ci/release-check/path-map.tsv` | changed path -> scenarios |
| `ci/release-check/extra-suite.tsv` | suite rows for examples outside `rig/examples/suite.tsv` (`loss`, the upgrade examples) |
| `ci/release-check/scope.py`, `plan.py`, `report.py` | scope, job plan with the cap, summary and draft note |
| `ci/release-check/recorded-rates.json` | rates measured before, per release, with their source run |
| `rig/examples/upgrade-restart.*`, `rig/examples/upgrade-mixed.*` | the upgrade examples |
