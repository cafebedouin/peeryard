# diffrun: differential scenario runner

Runs one multi-node scenario against a **base** node jar and a **candidate** node jar, N times each
(alternating base-1, candidate-1, base-2, ...), and turns the pooled results into one verdict against
an expected-outcome table. It is fail-before/pass-after for a live network: the base should show the
effect, and the candidate should not.

```
bash diffrun/build.sh <base-ref> [<patch>] [-- <pathspec>...]  # build + cache a jar (prints its path)
bash diffrun/register.sh <jar> <expected-appVersion>          # or register a pre-built jar
bash diffrun/run.sh <manifest.json> --base <jar> --candidate <jar> [-n N] [--out DIR]
bash diffrun/pool.sh --out DIR --shards S --pairs K <dir>    # one verdict over S runners' run.sh outputs
bash diffrun/lint.sh [file ...]                               # term-list lint (no args: public-tier scenarios)
```

A scenario is **an executable script that follows a contract, plus a small manifest**. There is no
topology DSL: the script owns the topology and the measurement; the manifest owns the parameters,
the tier and the expectations.

## Jars and sidecars

Every jar handed to `run.sh` needs a sidecar `<jar>.json` (`sidecar_schema_version: 1`) with at least
`jar_sha256` and `expected_app_version`.

- `build.sh` makes a scratch `git worktree` of `$DIFFRUN_ERGO_CLONE` at the base ref, applies the
  optional patch as one commit with a fixed author, committer, date and message, and runs `sbt assembly`
  under JDK 8. So the commit sha, and with it sbt-dynver's appVersion, depends only on the base and the
  patch. The patch is a file, a commit (its first-parent diff), or a range: `<a>..<b>`, or `<a>...<b>` for
  the diff from `merge-base(a, b)`, which is a pull request's diff once its head is fetched
  (`git -C $DIFFRUN_ERGO_CLONE fetch origin pull/N/head:pr-N`, then `master...pr-N`). A trailing
  `-- <pathspec>...` restricts a commit or range diff to those paths (`:!path` excludes). That is **hunk
  isolation by file**: build the base plus one part of a PR and the base plus the rest, and run the same
  scenario on each; for a finer split, cut the patch file yourself. `--dry-run` prints the patch that
  would be applied and its sha256 without building (it needs neither JDK 8 nor sbt). The jar is cached under
  `$DIFFRUN_CACHE/<base sha12>-<patch sha256 12>/`, with `<jar>.json` (source sha, patch type/ref/sha256/paths,
  build commit, jar sha256, expected appVersion from the jar name, `java -version`, sbt's JDK lines) and
  `<jar>.patch` (the full diff of the production dirs `src/main`, `ergo-core/src/main`,
  `ergo-wallet/src/main`, `avldb/src/main` between base and build commit). The entry is moved into
  place with one rename and is never overwritten; a repeat build re-derives the patch commit, checks it
  against the entry and serves the cached jar. ergo builds with `sbt-reproducible-builds`, and in practice the
  jar is byte-identical across builds of the same inputs: source builds of the v6.0.6 and v6.0.7 tags match the
  release assets' sha256, and GitHub-runner (Temurin 8) and local (OpenJDK 8) builds of the same base and patch
  match each other. Other JDK majors are untested, so run.sh still checks each jar against its own sidecar rather
  than across builds.
- `register.sh` writes a sidecar with only the jar sha256 and the claimed appVersion. The claim is
  checked on every run, so a wrong registration VOIDs that jar's runs. A sidecar sits next to the path
  given, so register a symlink to keep sidecars out of a shared jar directory.
  Registering a path that resolves to a `build.sh` jar takes the version from that build's sidecar when none
  is given, and refuses a different one unless `--override-version` is passed (`-f` only replaces a sidecar).

## The scenario contract

A scenario script
- takes the jar as `argv[1]`, and `WORKDIR` plus its parameters from the environment (the manifest's
  `env`); it must use `WORKDIR` for everything it writes; `DIFFRUN_ROLE` (`base` or `candidate`),
  `DIFFRUN_BASE_JAR` and `DIFFRUN_CANDIDATE_JAR` are also set, so a scenario can put both jars on one network
  (the `interop` scenario does); `PEERYARD_JAVA` / `PEERYARD_JAVA_OPTS` pass through to the nodes (`fork-convergence` and
  `sibling-fork` also use `PEERYARD_JAVA` for their own prerequisite check and the Java version they print);
- prints **exactly one** line
  `RESULT_JSON {"schema_version":1,"scenario":<name>,"versions":{<node>:<appVersion>,...},"metrics":{<key>:<number|boolean>,...}}`
  and exits 0;
- on a setup failure prints a line containing `INCONCLUSIVE: <reason>` and exits 3.

`run.sh` classifies each run:

| class | when |
|---|---|
| `VALID` | one well-formed `RESULT_JSON`, exit 0, and every `versions` value equals the jar's expected appVersion |
| `VOID (version-mismatch)` | as VALID, but some node reported another appVersion: excluded and counted |
| `INCONCLUSIVE (setup)` | no `RESULT_JSON`, exit 3 and an `INCONCLUSIVE:` line; or the manifest's `precheck` failed, in which case the scenario was not run (`precheck: "fail"` on the run, `setup: precheck` in the table) |
| `INCONCLUSIVE (no-result)` | no `RESULT_JSON` otherwise: crash, hang, timeout kill |
| `INCONCLUSIVE (malformed)` | 2+ `RESULT_JSON` lines, invalid JSON, wrong `schema_version` or `scenario`, empty `versions`, a declared metric missing or of the wrong JSON type |
| `INCONCLUSIVE (post-result-exit)` | a valid `RESULT_JSON`, then a nonzero exit or a signal |

Each run gets a fresh `WORKDIR` and its own process group, and is killed after `timeout_seconds`
(TERM, then KILL of the whole group 30 s later). Afterwards no process may remain in that group or
with the `WORKDIR` in its command line: a survivor keeps its network namespace alive, so it is a
runner ERROR that stops the suite (the survivors are killed and listed).

## Manifest

```json
{
  "name": "sibling-fork",
  "description": "...",
  "script": "sibling-fork.sh",
  "tier": "public",
  "env": { "D_AC": 500, "W": 150 },
  "metrics": { "D_total": "number", "D_confirmed": "number", "E_total": "number", "agreement": "boolean" },
  "n": 3,
  "min_valid_runs": 2,
  "timeout_seconds": 900,
  "expect": {
    "base":      { "count": { "key": "E_total", "op": ">", "value": 0 }, "cmp": ">=", "k": 1 },
    "candidate": { "all":   { "key": "D_confirmed", "op": "==", "value": 0 } }
  }
}
```

`"mixed_jars": true` marks a scenario whose topology puts both jars on one network (`interop`): its runs report both
versions, and a run is VALID when the role's own version and the other role's are both present (otherwise the
version check requires every node to report the role's version).

- `script` is relative to `diffrun/scenarios/` and must resolve (`realpath`) inside it.
- `env` values are strings or numbers, passed only through the environment (never `eval`'d).
- `expect` holds one predicate per role, over that role's **VALID** runs only:
  `{"any": C}`, `{"all": C}` or `{"count": C, "cmp": OP, "k": K}`, where `C` is
  `{"key", "op", "value"}` and `OP` is one of `== != > >= < <=`. A boolean metric may only be
  compared with `==`/`!=` against `true`/`false`.
- **Sequential rule** (optional, `max_n` and `stop_when` together): `n` becomes the minimum number of
  base/candidate pairs. From pair `n` on, the runner stops after any pair at which every `stop_when`
  predicate (per role, same vocabulary as `expect`, over the VALID runs so far) holds, and it stops at
  `max_n` pairs regardless. `verdict.json` records `n_min`, `n_run` and `sequential.stopped_by`
  (`rule` or `cap`). Stopping depends only on runs already finished, and the candidate always gets as many
  runs as the base.
- `min_valid_runs` defaults to `ceil(2N/3)` of the N pairs actually run. `timeout_seconds` defaults to 900.
- **Precheck** (optional, `precheck` and `precheck_timeout_seconds`, default 300): a floor gate. The script,
  relative to `diffrun/scenarios/` like `script`, runs before **each** scenario run with the same jar and
  env and a `WORKDIR` of its own (`runs/<role>-<i>/precheck`, kept on failure). It exits 0 when the floor
  holds; otherwise it prints an `INCONCLUSIVE: <reason>` line and exits nonzero, the run is classified
  `INCONCLUSIVE (setup)` and the scenario is not launched, so a broken environment or a jar that cannot
  form a network on this host produces a DEGENERATE verdict instead of counting as evidence. Two are
  provided, both wrapping a `rig/examples/` check: `precheck/poscontrol.sh` (two isolated miners must
  diverge and the comparator must see it, ~1 min) and `precheck/floor.sh` (a sole-peer follower fully
  syncs and a restart keeps the chain, 2–3 min). `verdict.json` records `precheck.script` and the number of
  failed prechecks; each run carries `precheck: "pass" | "fail" | null`.
- `n` is the intended repeat count; a `-n` override is recorded in `verdict.json` (`n_overridden`),
  because `count(...) >= k` thresholds assume the manifest's `n`. Under the sequential rule a `-n` larger than
  `max_n` also raises the cap to that value; the cap actually used is recorded as `sequential.max_n_effective`
  and the table says when it differs from the manifest's.

The manifest is validated at load (`lib/diffrun.jq`), before anything runs: unknown fields, missing or
mistyped fields, an undeclared metric in `expect`, a type-mismatched comparison, a bad env value or a
script outside `diffrun/scenarios/` each reject it.

## Verdict

First match wins:
1. **DEGENERATE**: either role has fewer than `min_valid_runs` VALID runs.
2. **AGAINST**: the candidate's predicate fails (whatever the base did).
3. **NULL**: the base's predicate fails (the effect was not reproduced).
4. **SUPPORTS**.

`verdict.json` carries both roles' raw `pass` booleans in `per_role`, so the verdict can be re-derived
under another precedence, plus every run's role, index, class, versions and metrics, and a named `cause` where one is
known: a code only (`^[A-Z_]{3,40}$`), never free text: a hook's own (`[rig] CAUSE (hook) X`), a scenario's die code
(`CAUSE X`, e.g. `SETUP_PREFIX_RACE`, `SETUP_NODE_API`, `SETUP_SYNC`, `SETUP_FORK_STAGING`), or the rig classifier's
(`diag/diagnose.py`); the evidence text stays in the run's `metadata.json` (`cause_evidence`). The table prints it. It also carries
`provenance` (the scenario script's and the precheck's sha256, the manifest `env`, the runner's git revision, and
`host`: kernel, cpu count and memory, no hostname, because an A/A rate is a per-host number),
`same_jar` (true when both roles ran the same jar: an **A/A control**, whose verdict says nothing about a
change and is labelled so in the table) and `n_overridden` (a `SUPPORTS` reached under a `-n` override is
labelled "not citable" in the table, because the false-SUPPORTS rates below assume the manifest's `n`).
`table.txt` is the same for humans. `examples/` holds one finished run of each kind.

**Log comparison (after the verdict).** Every VALID run keeps its node logs, gzipped, under `runs/<role>-<i>/logs/`
(the node data is removed; `DIFFRUN_KEEP_WORK=1` keeps everything). After writing the verdict, `run.sh` calls
`logab.sh <out>`, which compares the base runs' logs with the candidate runs': `logab_features.txt` ranks the per-run
log features that separate the two arms (`diag/features.py`), and `logab_novelty.txt` lists what the candidate runs
log that no base run did (`diag/sweep.py --baseline`). It does not change the verdict: it lists what else differs
between the two jars, as candidates to read. On an A/A run it shows how much two identical arms differ by chance.
`DIFFRUN_LOGAB=0` skips it; `DIFFRUN_LOG_SOURCE=<node source checkout>` names the code line behind each message.

Outputs under `--out`: `verdict.json`, `table.txt`, `manifest.json` (snapshot), both sidecars,
`runs.jsonl`, `run_meta.json` (private: diffrun git rev, command line, local paths, term-list sha256; never
upload it), and per run `runs/<role>-<i>/{stdout.txt,stderr.txt,result.json,metadata.json}` plus, with a
precheck, `precheck.stdout.txt` and `precheck.stderr.txt`. The `WORKDIR` (`runs/<role>-<i>/work`) is kept
only for VOID and INCONCLUSIVE runs; a precheck's `WORKDIR` only when it failed.

Exit codes: 0 verdict written (any verdict); 2 runner ERROR (unparseable or rejected manifest, a jar whose
sha256 does not match its sidecar, a workdir failure, a leftover process) and **no `verdict.json`**;
4 refused before launching (tier guard, input lint); 5 refused to write outputs (output lint).

**Pooled verdict over shards (`pool.sh`).** A hosted before/after run can be split over S runners, each a
`run.sh --out` of K pairs (so each runner's host variance hits both arms), collected as `<dir>/shard-<k>/`.
`pool.sh` pools every shard's runs (each keeps its `role` and `index` and gains `shard`) and applies the same
`role_summary`/`decide` once, over P = S*K dispatched pairs, with the manifest's `min_valid_runs` or else
ceil(2P/3). A vote over per-shard verdicts would be a different test (`tests/diffrun_pool.sh` has a case where
every shard is NULL and the pool is SUPPORTS). A shard with no readable `verdict.json` or `manifest.json`, or
with fewer than K pairs, is **lost**: it adds K `INCONCLUSIVE (lost-shard)` runs per role, so it counts against
`min_valid_runs` instead of shrinking the denominator. Shards that differ in the manifest snapshot, a jar sha256,
`same_jar` or provenance (the host aside), a shard that ran the sequential rule or more than K pairs, and a pool
with no shard present are refused (exit 2, no verdict). The pooled `verdict.json` adds `pooled` (per shard
present/runs, `pairs_dispatched`, `min_valid_source`), `provenance.hosts` (one per present shard) and
`pooled_n_differs` (P differs from the manifest's `n`: a SUPPORTS is labelled "pooled n differs: not citable";
per-shard `-n K` is expected, so `n_overridden` is false).

## Private runs

Manifests carry a `tier`; `run.sh` refuses a `private` one under CI and can lint inputs and outputs against a
term list you supply. Details, exit codes 4 and 5, and what the lint does not do: `PRIVATE-RUNS.md`.

## Scenarios

| name | tier | what | base expectation | candidate expectation |
|---|---|---|---|---|
| `sibling-fork` | public | 4 nodes, 2 miners behind a slow link; best full block vs best header on different forks at one height (the base counts single samples, `E_total`; the candidate is judged on `D_confirmed`, the same state in two consecutive samples) | `count(E_total > 0) >= 1` | `all(D_confirmed == 0)` |
| `fork-convergence` | public | a follower on a lighter static fork meets a heavier fork | `count(switched == false) >= 2` (sequential: min 8, cap 12) | `all(switched == true)` |
| `interop` | public | the release jar and the candidate jar on one two-node network (rig hook), each mining in turn while the other follows | `all(interop == true)` | `all(interop == true)` |
| `txload` | public | real payments from a miner's wallet on a two-node network (rig hook): judged on confirmations; acceptance and the count in blocks are recorded | `all(confirmed == 10)` | `all(confirmed == 10)` |
| `bootstrap-modes` | public | a miner with a digest-mode follower and a pruning follower, three nodes (rig hook): judged on state-root agreement; settling and visible pruning are recorded | `all(state_agree == true)` | `all(state_agree == true)` |
| `indexer-diff` | public | the extra indexer of both jars on one chain (rig hook `rig/examples/indexer-diff.sh`, `mixed_jars`): a miner, X on this role's jar and Y on the other's, both indexing; `/blockchain` answers compared at settled points after payments and a token issue, a restart of Y and a rollback of Y; a positive control must show DIFF (else INCONCLUSIVE); a follower that has not switched 60 s after the fork's heal is relaunched once (`fork_follower_restarted`). `rig/INDEXER-DIFF.md` | `all(agree == true)` | `all(agree == true)` |
| `wallet-oracle-restart`, `wallet-oracle-fork` | public | the wallet oracle (`rig/WALLET-ORACLE.md`), every node on this role's jar: a subject wallet goes through each lifecycle event in `WO_EVENTS` (restart example: `restart`, `crash`, `rescan`, `none`, `rescan-from`; fork example: `fork`, `none`, `rescan-from`), one rig network per event, and is compared field by field with a reference wallet that went through nothing; `WO_AT=pending` (restart example) compares before the pending payment confirms. `same` = every event SAME; an INCONCLUSIVE event makes the run INCONCLUSIVE. Parameters are the manifest's env, overridable per dispatch (`pr-scenario.yml` `scenario_env`, `diffrun/scenario-env.sh`). The predicates are the before/after shape; a change that should leave the wallet alone reads as NULL with both roles `same` | `any(same == false)` | `all(same == true)` |
| `wallet-workload` | public | the wallet workload ([`rig/WALLET-WORKLOAD.md`](../rig/WALLET-WORKLOAD.md), rig hook `rig/examples/wallet-workload.sh`, `mixed_jars`): a miner on the base jar, the wallet under test on this role's jar, the same wallet restored on a node running the other role's jar; every step's invariants judged (`rig/lib/wallet_check.jq`); `wallet-workload-plain` is the sequential A/A step list, `wallet-workload-posctl` the positive control (`all(control_tripped == true)`) | `all(pass == true)` | `all(pass == true)` |
| `crash-consistency` | public | a follower S SIGKILLed 3-5 times at random points inside block bursts and restarted from its own disk each time, every node on this role's jar (rig hook `rig/examples/crash-consistency.sh`, classifier `rig/crash-verdict.sh`, `rig/CRASH-CONSISTENCY.md`); `same` = S on the untouched follower's and the miner's best full block and state root, REST up, no unrecoverable log line; fewer than half the kills inside a burst makes the run INCONCLUSIVE. The hook's `CC_*` knobs (role, indexer, kill mode) go in a copy of the manifest's env | `all(same == true)` | `all(same == true)` |
| `storage-rent-2598` | public | a miner collecting storage rent itself (ergoplatform/ergo#2598) on this role's jar, with a base-jar and a candidate-jar follower (rig hook `rig/examples/storage-rent-2598.sh`, `mixed_jars`, `docs/storage-rent.md`); both jars need the devnet test patches (`pr-scenario.yml` `test_patches="patches/test/storage-period-60.patch patches/test/rent-distinct-outputs-devnet.patch"`). `pass`: a jar that can collect (its `application.conf` has `storageRentCollection`) must put claims in its blocks, all within the rule, claim every holder box and keep both followers on its state root; a jar that cannot (the base role, and both roles of an A/A) must show 0 claims with the same agreement (`c_can_collect`) | `all(pass == true)` | `all(pass == true)` |
| `relay-floor`, `relay-floor-12`, `floor-spam`, `floor-spam-360` | public | the per-peer transaction budget of ergoplatform/ergo#2641 under real wallet load (rig hook `rig/examples/relay-floor.{json,sh}`, four nodes, one jar): a relay R with a lower fee floor (100,000) forwards payments that the strict node S declines, interleaved with valid ones; `relay-floor` eight bursts, `relay-floor-12` twelve (sustained load); `floor-spam` the same relay forwarding only sub-floor payments (120 per block; `floor-spam-360` 360), the shape the per-peer quota is for. Measured: valid payments through R and from an unrelated peer Q that reach S only after the next block, unmined payments, declines per interval at S; below the activity floor (fewer than 4 intervals with 50 declines at S, or fewer than 40 valid sends per payer) a run is INCONCLUSIVE. The `relay-floor*` expectations encode the hypothesis of #2641's thread (the candidate delays R's valid payments past a block); `floor-spam*` hold both jars to `q_missing == 0` | `relay-floor*`: `all(p_delayed_past_block == 0)`; `floor-spam*`: `all(q_missing == 0)` | `relay-floor*`: `count(p_delayed_past_block > 0) >= 3`; `floor-spam*`: `all(q_missing == 0)` |
| `matrix-paychain` | public | Matrix line (weak-blocks) only: bursts of 40 wallet payments on a two-node network (the rig example's hook, `rig/examples/matrix-paychain.{json,sh}`); a payment is lost when it ends neither confirmed nor in the miner's pool; fewer than 30 accepted (`MATRIX_PAYCHAIN_FLOOR`) makes the run INCONCLUSIVE. Predicates fitted to one hosted run (base lost in 5/5, base + ergoplatform/ergo#2504 in 0/5), so a SUPPORTS on #2504 re-runs the workflow, not the hypothesis | `count(lost > 0) >= 3` | `all(lost == 0)` |
| `fork-convergence-smoke`, `sibling-fork-smoke` | public | one pair, no cited verdict: does the scenario still complete with every node answering afterwards (a cheap tier for pull-request CI) | `all(unresponsive_after == 0)` | `all(unresponsive_after == 0)` |
| `test/output-lint-stub` | public | test only: no nodes; its result carries a lint-listed term built at runtime | | |
| `test/seq-replay`, `test/precheck-replay` | public | test only: no nodes; replay a scripted per-run pattern (`tests/sequential.sh`, `tests/precheck.sh`) | | |

Of the node scenarios, `fork-convergence` and `sibling-fork` are standalone scripts (their own namespace code plus
the `RESULT_JSON` emission); the two `wallet-oracle-*` manifests share `scenarios/wallet-oracle.sh`, which runs the rig
example once per event and folds the oracle's verdict lines into one `RESULT_JSON`; the rest (`interop`, `txload`,
`bootstrap-modes`, `matrix-paychain`, `indexer-diff`, `crash-consistency`, `storage-rent-2598`, the four `relay-floor`/`floor-spam` manifests and the three
`wallet-workload` manifests) are rig hooks run through `scenarios/lib/rig-scenario.sh`. `matrix-paychain` reuses the rig
example's topology and hook, which emits `RESULT_JSON` only when `DIFFRUN_ROLE` is set; `indexer-diff` and
`crash-consistency` reuse their rig examples' topology and hook as they are; `storage-rent-2598` and `wallet-workload`
reuse the rig example's hook with their own topology (`scenarios/hooks/<name>.json`, both jars on one network). The standalone scripts report the `versions` each queries at startup, so
identity is settled while every node is known to be up. `unresponsive_after` counts the nodes whose REST
no longer answers once the measurement is over. It is recorded but does not void the run, and a nonzero
count means that node's log is worth reading.

`fork-convergence` uses the sequential rule: at least 8 pairs, stop once base has failed to switch
twice, cap 12. It requires base `count(switched == false) >= 2` and candidate `all(switched == true)`.
A false SUPPORTS is the expensive error, because SUPPORTS is the verdict that gets cited. The released
node's switch rate is thin data (the A/A calibration in `examples/fork-convergence-aa-6.0.6/`: 8 of 16 runs
switched on 6.0.6 on one development host, exact 95% interval 0.25–0.75; on GitHub-hosted `ubuntu-24.04` runners,
the citable class, 23 of 40 switched, interval 0.41–0.73, `aa.yml` run 36289967948 of 2026-09-27; on the reference node,
the release plus the carried patches, 40 of 40 switched, interval 0.91–1.00, run 36299847716: a candidate is compared
against the line that applies to the jar it was built on; a second 8-pair run on the development host, under other load, gave
5 of 16, interval 0.11–0.59: the host number moves, the runner-class number is the one to cite) and has to be re-measured on each release and host
(an A/A run, the same jar in both roles, measures it), so the rule is chosen to hold across the range. Simulated with `tests/stop_rule_sim.py
--trials 200000 --seed 1` (standard library only, about 10 s on one development host; the table below is its output for the
shipped rule):

| base switch rate | false SUPPORTS (candidate no better) | SUPPORTS for a candidate that always switches | mean pairs |
|---|---|---|---|
| 0.57 | 1.1% | 98.8% | 8.2 |
| 0.70 | 4.7% | 91.5% | 8.7 |
| 0.85 | 13.4% | 55.7% (the other 44% end NULL at the cap) | 10.3 |

For comparison, at 0.57: the same stop rule with a minimum of 3 gives 10.5% false SUPPORTS, because it
stops before the candidate has run enough for "all switched" to mean much. A fixed n=3 with the shipped
two-failure base predicate gives 7.3% but detects an always-switching candidate only 39.6% of the time
(fixed n=6: 2.8% and 81.0%); with a one-failure base predicate, fixed n=3 gives 15.2% and fixed n=6 3.3%.
That is why the minimum matters. At high base rates the scenario cannot discriminate, and the verdict
should come out NULL rather than SUPPORTS.

Known limits:
- **Repeated runs are not independent samples.** Block timing on a devnet is quantised by the miners'
  polling intervals, so runs of one scenario on one machine share structure; N runs are N observations of
  that machine, not N draws from the network at large. Treat the false-SUPPORTS rates above as indicative.
- **`/peers/connected` is not connectivity.** A cut link keeps its TCP peers listed for minutes, so a peer
  count proves nothing about whether traffic flows; the scenarios measure chain state, not peer lists.
- `fork-convergence` runs its `main` mode unless a manifest sets `FC_MODE: reverse` in `env` (the mode is `argv[2]`,
  which the contract does not pass, or `FC_MODE`); no shipped manifest sets it, so no A/A rate exists for `reverse`.
- **A switch must hold.** `fork-convergence` counts a follower's switch only if, 60 s later, it still holds the
  other fork's header id at the fork height and both followers are on one tip; a switch that did not hold is not
  counted (the `RESULT` line says so). In the standalone `reverse` mode a switch of L is the unexpected outcome,
  so it stays reported even if L later went back.
- **Unreadable header ids void a run, they are never read as a fork.** Both standalone scenarios read header ids
  with retries: an empty REST reply is retried `HDR_TRIES` times (default 5, 1 s apart; settable in a manifest's
  `env`). `fork-convergence` is INCONCLUSIVE when an id it needs stays unreadable (genesis, the fork search, the
  fork height, the tips, the re-check after the hold) or when the fork height found is at or below `PREFIX_MIN`
  (the prefix both miners shared, where no real fork can be). `sibling-fork` is INCONCLUSIVE when an id for the
  agreement check stays unreadable or when the lowest full height minus 5 is below 1.
- `sibling-fork` prints a note when heights reach 128 (the devnet's version-2 activation height, a one-off difficulty reset) but still reports, so
  `max_height` is a metric a manifest may constrain; the shipped manifest does not.
- `sibling-fork`'s candidate predicate is `D_confirmed`: a mismatch a node reported in two consecutive samples,
  as the regression spec in `regression/` also requires (one sample can be body-download lag). `D_total`, the
  single-sample count, is still recorded. The shipped A/A example `examples/sibling-fork-aa-control/` predates
  `D_confirmed` (its table judges `D_total`, one pair). The rate measured on the development host on 2026-09-25 was
  15 of 16 release runs with a confirmed divergence, and 0 of 16 on the reference node (`patches/ergo/patches.json`,
  003); on GitHub-hosted runners the release diverged in 20 of 20 runs (`D_confirmed > 0`, interval 0.83–1.00, the
  same `aa.yml` run) and the reference node with #2313 in 0 of 20 (interval 0.00–0.17, run 36299847716). It is a per-host number, so run an A/A on your host before citing a `sibling-fork` verdict.
- The shipped manifests declare no `precheck`; add one when the host or the jar is new.
- **Setup INCONCLUSIVEs happen.** `fork-convergence` stages its fork with timed waits (a holder must lead by
  `DELTA` blocks within its window); on the authors' host about one base run in six ended `INCONCLUSIVE
  (setup)` ("heavier holder S did not reach +8"). Such a run is excluded and recorded, never counted; the
  sequential rule and `min_valid_runs` absorb it, but a one-pair run can come out DEGENERATE for that reason
  alone. Re-run rather than lower `DELTA`.
- One host bounds the node count (about 350 MB per node). On a GitHub-hosted `ubuntu-24.04` runner the rig's
  requirements hold after `sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0` and
  `sudo modprobe sch_netem` (the rig and the scenarios need `sch_netem` only; `sch_prio` and `cls_u32` are the
  regression sidecar's). Checked once on such a runner: a two-node bringup with the release jar, the sidecar
  shape and the self-tests all passed there. Whether a full 1.5–2.5 h scenario suite keeps its timing on a two-vCPU runner is a
  separate question, see below.

## GitHub Actions

`.github/workflows/pr-scenario.yml` runs one public manifest before and after an ergoplatform/ergo pull request on
GitHub-hosted runners: one build job builds both jars from one build base (the base, and the base plus the PR's
production diff), `shards` runners each run `pairs` pairs, and `pool.sh` judges the pooled runs once. Inputs:

| input | what |
|---|---|
| `pr`, `head` | the pull request and its head commit (40 hex; the run fails if the PR has moved); ignored with `aa` |
| `line` | the build base: `matrix` (the weak-blocks commit in `patches/ergo-matrix/patches.json`), `matrix-stack` (that commit plus the carried Matrix stack, the PR's diff stacked last), a release tag `vN.N.N`, or a commit (40 hex, e.g. the PR's own merge base when its diff does not apply on a release) |
| `scenario`, `shards`, `pairs` | the manifest basename (public tier, no `stop_when`/`max_n`), runners (1-20), pairs per runner (1-99) |
| `aa` | A/A: the base jar in both roles, no PR fetched |
| `v4` | Matrix lines at block version 4 (rig `PEERYARD_V4`) |
| `test_patches` | release-tag or commit lines only: space-separated test-only patches under `patches/test/`, applied to both arms as one local commit on the line's commit, which becomes the build base (e.g. `storage-rent-2598` needs the storage-period and rent-distinct-outputs patches) |
| `extra_patch` | any line, not with `aa`: one patch file under `patches/` (not `patches/test/`), a proposed change to the PR, applied to the **candidate only**: committed on the PR head, so the candidate is the build base + the PR's diff + this patch (production paths only) and the base arm is unchanged. One dispatch compares base against PR + patch; to read the patch against the PR alone, compare its candidate arm with a run of the same scenario and line without `extra_patch` (e.g. `patches/ergo-2641/`) |
| `scenario_env` | `KEY=VALUE` overrides of the manifest's env, `;`-separated, only keys the manifest declares, values `[A-Za-z0-9._ :,-]` (`scenario-env.sh`); the effective env is in `verdict.json`'s provenance |

The PR's diff is taken from git's merge base, which must be an ancestor of the line's commit; when the line's commit is
one of the PR's several merge bases (a PR that merged its base branch in), the diff is taken from that commit itself.
With `test_patches` these checks still run against the line's commit, not the local test-patch commit. The two patch
inputs differ in which arm they reach: `test_patches` both (a test condition, never proposed upstream), `extra_patch`
the candidate only (a change under test); the build summary names either with its sha256. The run's title
carries `A/A` or `#<pr>`, ` + <extra_patch>` when set, the line, `shards x pairs`, and ` v4`, ` +test patches` and ` [<scenario_env>]` when set
(`review/release-check.sh` finds its dispatches by that title).

`ci/diffrun.yml.example` is a `workflow_dispatch` workflow: it lints first, builds base and candidate with
`build.sh`, runs the public-tier manifests and uploads only `verdict.json` and `table.txt`.
`ci/diffrun-hosted.yml.example` is the variant that was actually run: the release jar downloaded as base, the
candidate built on the runner from a pull request's own diff (`master...pr-N`) or downloaded from another
release tag. On one GitHub-hosted `ubuntu-24.04` runner (2 vCPUs, 8 GB: the private-repository class) the suite of that time
(`fork-convergence`, `sibling-fork`) ran with its timing intact: the candidate (v6.0.6 + #2511's production
diff) built in about two minutes; `fork-convergence` ran 8 pairs, 16/16 VALID, stopped by the rule, verdict
SUPPORTS (base switched 6/8, candidate 8/8); `sibling-fork` ran 3 pairs, 6/6 VALID. Run durations matched the
development host's (about 175 s for a switch, about 415 s for a non-switch); the whole job took 78 minutes.
That run is an example of the workflow, not a headline result: it compares an upstream-built release jar with a
locally built candidate (two differences, the patch and the toolchain), and it ran on a hosted runner, while the
only `fork-convergence` A/A calibration is from the development host, so its rate is not comparable with it
(`examples/README.md`). Read a hosted verdict's INCONCLUSIVE counts as you would a local one. `ci/release-watch.yml.example` polls ergo's releases and dispatches a
release-versus-release run when a new tag appears in a release line.
