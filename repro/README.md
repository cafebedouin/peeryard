# repro/

Each directory here is one self-contained reproduction for one upstream pull request or issue: a `run.sh` that states
a claim in its header, pins the commits it tests by full sha, fetches or builds what it needs, runs, and decides. It is
not a scenario and not a rig example. A scenario under `diffrun/scenarios/` is a manifest that `diffrun/run.sh` runs N
paired times on any base and candidate jar you hand it, ending in `SUPPORTS` / `AGAINST` / `NULL` / `DEGENERATE`; a rig
example under `rig/examples/` is a topology and a hook that `rig/rig.sh` runs once on the jars you give it, ending in
PASS / FAIL / INCONCLUSIVE, and is listed in `rig/examples/suite.tsv`. A repro takes no jar and no manifest: the
commits, the patches and the expected output lines are written into the script, so it answers one question about one
change and nothing else. Most build their own jars with `diffrun/build.sh` on the pull request's merge base, or run
ergo's own specs with `sbt testOnly` at fixed commits, and several load a node jar into a small Java harness that sits
beside `run.sh`.

**The contract of `.github/workflows/repro-script.yml`** (its header, lines 1-2): it runs `repro/<dir>/run.sh` on one
`ubuntu-24.04` runner; "the script decides the verdict: it must end with a VERDICT line and exit non-zero when its
claim does not hold." The workflow takes one input, `dir`, checks that it matches `^[a-z0-9][a-z0-9-]*$` and that
`repro/<dir>/run.sh` exists, prints `sha256sum repro/<dir>/*`, runs the script with `WORKDIR=$RUNNER_TEMP/work` and
`pipefail` (so the script's exit status is the job's), and uploads the output as the artifact `repro-<dir>`. It sets up
Temurin JDK 8 and sbt; any other JDK a script asks for is read from the runner's `JAVA_HOME_<v>_X64`. The job has a
60-minute limit (`timeout-minutes: 60`). The scripts that follow the contract print `VERDICT: as claimed` (exit 0) or
`VERDICT: NOT as claimed` (exit 1), and use exit 2 for a setup failure.

**Per-directory `.shellcheckrc`.** `checks.yml` runs `shellcheck -x` on every bash script in the tree, and shellcheck
reads the nearest `.shellcheckrc`, which replaces the repository's one rather than adding to it. A published script
whose bytes a posted review cites (repro-script.yml prints their sha256) is not edited for a style note; instead its
directory gets a `.shellcheckrc` that disables that one check and repeats the repository-wide exceptions, with a comment
naming the line (commit 14ad07b: SC2004 at `repro/ergo-2332-log2-ab/run.sh:51`). Being a dotfile, it is outside
repro-script.yml's `sha256sum repro/<dir>/*`, so the printed hashes do not change.

## Index

"repro-script" in the *runs* column means the directory fits the workflow's contract (a `run.sh` with no arguments and a
VERDICT line); every such script also runs locally with `bash repro/<dir>/run.sh`. Times are the scripts' own estimates.

| directory | concerns | checks | runs | needs | added |
|---|---|---|---|---|---|
| `ergo-2332-log2-ab/` | ergoplatform/ergo#2332 (head 067ced2a, merge base v6.0.5); `LevelAB.java` also cites issue #2556 | Whether the NiPoPoW level computed with each jar's own `NipopowAlgos.log2` differs between the base and the PR on about two million rows near level boundaries and at random, on JDK 8-25 in default, `-Xint` and `-Xcomp` modes, and which class the PR's canary triple falls in per JDK. | repro-script, or local; header: about 9 minutes on a hosted runner | git, sbt, curl; JDKs 8, 11, 17, 21 (JDK 25 is fetched and checked by sha256 if absent); two jars built with `diffrun/build.sh` | 2026-11-21 |
| `ergo-2461-keep-deployed-form/` | ergoplatform/ergo#2461, and three commits on branch `nipopow/keep-deployed-proof-form` of cafebedouin/ergo (`patches/ergo-2461/`) | Whether the NiPoPoW suites fail exactly the three new tests at the tests-only commit and pass at the two fix commits stacked on the PR head. | repro-script, or local; header: about 20 minutes on a hosted runner | git, sbt, JDK 8 | 2026-11-17 |
| `ergo-2519-snapshot-lock/` | ergoplatform/ergo#2519 (head 214b2dcc, merge base c1a69f65, v6.0.8) | A revert check of the PR's `LDBVersionedStoreSnapshotSpec`, then an A/B of base and candidate jars through `SnapshotAB.java` on native LevelDB, with injected failures in `processSnapshot`'s acquisition, processing and close, each output line compared with the one listed per jar. | repro-script, or local | git, sbt, JDKs 8, 11, 17, 21, x86_64 Linux (leveldbjni); two jars built with `diffrun/build.sh` | 2026-11-22 |
| `ergo-2519-spec-returned/` | ergoplatform/ergo#2519 (same head and merge base) | Whether a one-line change to two lines of the PR's spec (`spec-returned.patch`) makes it reject a mutant (`mutation-acquisition-outside-try.patch`) that the unchanged spec accepts, across five sbt runs of the spec. | repro-script, or local | git, sbt, JDK 8; optional `ERGO_CLONE` to fetch from | 2026-11-22 |
| `ergo-2937-token-whitelist/` | ergoplatform/ergo#2937, issue #2935 (head a26b13b7, merge base v6.0.11) | Whether the candidate refuses malformed token-whitelist settings with the stated message and the base accepts them, over 35 settings inputs read by `WhitelistAB.java` and five `--devnet` node starts. | repro-script, or local | git, sbt, curl, JDK 8, free TCP ports 19052-19061 on 127.0.0.1; two jars built with `diffrun/build.sh`; starts node processes | 2026-11-22 |
| `ergo-2942-2958-modifiers-count/` | ergoplatform/ergo#2942 and #2958, issue #2918 | Revert, cross and mutant checks of both PRs' `ModifiersSpecification`, then `ModifiersAB.java` parsing the same Modifiers payloads with three jars (base, #2942, #2958) and comparing each line with the one listed. | repro-script, or local | git, sbt, JDKs 8 and 21, about 2 GB of heap; three jars built with `diffrun/build.sh` | 2026-11-22 |
| `ergo-ldb-close-waits-for-snapshots/` | no upstream issue or PR named in the files [UNVERIFIED]; the commit message names the release, v6.0.11 and a "fixed" jar | What happens when an `LDBVersionedStore` is closed while `processSnapshot` still uses its snapshot (cases C0-C3, ordered by latches), one JVM per jar, JDK and case, printing each case line, exit code and any JVM crash summary. | local only: `bash run.sh <label>=<jar> ...`; it takes jar arguments and prints no VERDICT line, so it does not fit repro-script.yml | JDK 8 (`javac`, `java`), JDK 21 optional; x86_64 Linux; the node jars you pass | 2026-11-22 |
| `interlink-roots/` | the NiPoPoW proof-form question behind ergoplatform/ergo#2461 (added in the same commit, af5f8f1; cited from `patches/ergo-2461/README.md`) | Whether the Merkle root of a header's interlinks alone differs from its `extensionHash` exactly at the first block of a voting epoch, for the headers of a proof a mainnet node serves. | repro-script, or local (`NODE=` names the node; default a public mainnet node); exit 2 means inconclusive (no answer, or no voting-epoch start among the headers), not a setup failure | python3 (standard library), network access to an Ergo mainnet node | 2026-11-17 |
| `matrix-uncles/` | the Matrix input-block uncles measurement on the weak-blocks line; the issue it tests is not named in the file [UNVERIFIED]; both builds carry #2562 | Re-runs the measurement by dispatching `patch-compare.yml` 21 times on branch `matrix-value-instr` (pinned to peeryard 6003c57) and prints per-run bytes, requests, credited uncles and refused shares, against the issue's thresholds listed in the header. | local driver of hosted runs: `uncles-compare.sh`, not `run.sh`; it dispatches workflows itself (header: each dispatch took 2.7 h wall time; `QUICK=1` dispatches one). Its last line is `VERDICT OK` or `VERDICT CHECK (...)`. Read `CLAUDE.md` and size the batch before running it | bash 4+, `gh` authenticated with dispatch permission, jq, python3, sha256sum; nothing is built locally | 2026-10-10 |
| `sigma-rust-917-deployed-proof/` | ergoplatform/sigma-rust#917 | Whether sigma-rust's NiPoPoW verifier keeps a mainnet proof on the v0.30.0 branch and rejects it at the PR head with one failing interlink check at height 1821696. | repro-script (added with the workflow, commit 53e5934), or local | git, curl, tar, a Rust toolchain (`cargo`), about 3 GB of disk; no JDK | 2026-11-14 |
| `jdk8-cpu-log/` | untracked work in progress (not committed) | Not described here: no `run.sh`, no commit, nothing to cite yet. It holds `CpuLog.java` and `x87log.c`; `CpuLog.java`'s header names the rows of `ergo-2332-log2-ab/LevelAB.java` as its inputs. | none yet | - | - |

## Adding one

The conventions the committed directories share:

- **Name** `ergo-<N>-<short-topic>` for an ergoplatform/ergo PR or issue (`ergo-<N>-<M>-...` when two PRs answer one
  issue), `sigma-rust-<N>-...` for sigma-rust; a topic name only when no single number fits (`interlink-roots`,
  `matrix-uncles`). The name must match `^[a-z0-9][a-z0-9-]*$` for repro-script.yml.
- **`run.sh` and its header.** The header says, in this order: what is tested, at which commits (full shas of the head
  and the merge base, and the PR's title); the **Claim**; **What counts against it**; the last-line rule ("VERDICT: as
  claimed" exit 0, "VERDICT: NOT as claimed" exit 1, exit 2 a setup failure); **Needs** (tools, JDKs, network, ports);
  **Touches** (only `WORKDIR`, apart from sbt's, coursier's or cargo's caches); **Stop** (Ctrl-C, and what is left
  behind); **Quick mode** (usually none) and a time estimate.
- **Pinned inputs.** Commits by full sha, checked with `git merge-base` or `rev-parse` before anything runs; the script
  prints the PR's current head next to the tested one. Downloaded files are checked by sha256 (`sigma-rust-917`'s
  fixture and crate, `ergo-2332`'s JDK 25). The expected output lines are written into the script (`WANT_BASE`,
  `WANT_CAND`, `expected_v030`) and compared exactly.
- **Jars.** Built with `diffrun/build.sh <merge base>` and `diffrun/build.sh <merge base> <mb>...<head> -- src/main
  ergo-core/src/main ergo-wallet/src/main avldb/src/main` (production paths only), with `DIFFRUN_NO_LOCK=1` and
  `DIFFRUN_CACHE` under `WORKDIR` unless set.
- **Environment.** `set -uo pipefail` (`-euo` in `sigma-rust-917-deployed-proof/` and `matrix-uncles/`); `WORKDIR`
  defaults to a fresh `mktemp -d`, printed first and kept; `XDG_RUNTIME_DIR` defaults to `/tmp/sr-<uid>` for sbt. JDKs
  come from `JAVA_HOME_<v>_X64` (hosted runner) and then a local variable; the local name varies between scripts
  (`JDK<v>_HOME`, `JAVA8_HOME`, `JDK8_HOME`), so read the header.
  The CPU model and `uname -m` are printed when the result could depend on them.
- **Harness files** sit beside `run.sh` (`*AB.java`, `.patch` files, `.rs` tests, `.py`), are compiled or applied by it,
  and are hashed in the output (repro-script.yml hashes the whole directory).
- **Style exceptions** go in a directory `.shellcheckrc` (above), never into edits of a script a review has cited.
- A directory whose script needs arguments, or that dispatches workflows, does not fit repro-script.yml; say so in its
  header (`ergo-ldb-close-waits-for-snapshots/`, `matrix-uncles/`).
