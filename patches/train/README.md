# Composites of open pull requests ("trains"), for patch mode

Each file is several ergoplatform/ergo pull requests' production diffs applied in order on one line commit, as one
patch: the node a branch becomes if those PRs merge. It is **a composite of public PRs, not a release**, and nothing
here is proposed upstream as a change of its own. Run one with pr-scenario.yml's patch mode (`extra_patch` with `pr`
empty; base arm = the line, candidate = the line + the patch) or with `review/release-check.sh dispatch --patch <file>
--line <commit> --ref <the branch carrying the file>`.

Made with `build-train.sh` (each PR's `<base branch>...<head>` diff over `src/main ergo-core/src/main
ergo-wallet/src/main avldb/src/main`, the same dirs pr-scenario.yml builds from, applied with `git apply --index` and
committed in the order given; the file is the diff from the line to the last commit). A file is never edited: a PR that
moves gets a new file with a new date. Re-derive one with the command in its row and compare the sha256.

| file | line | PRs, in apply order (head) | sha256 | made with |
|---|---|---|---|---|
| `v6.0.9-approved-2026-10-16.patch` | v6.0.9 tip `4f354391d144049160ebf0eda4fa1bab56cc85ef` | #2411 `bdc9165d`, #2507 `52fa2b37`, #2517 `b8892a59`, #2518 `114add1c`, #2527 `7bd94a6e`, #2655 `6a3ed687`, #2662 `23659bf4`, #2664 `f95af817`, #2675 `626e5ca8`, #2680 `d4019b69` (the PRs on v6.0.9 that were approved, mergeable and green on 2026-10-16; all ten applied, none conflicted; 12 files, +360 -150) | `4685e063e0153c7600ec546d23fa587615380e5e4c3815153ce01cb812f66a10` | `DIFFRUN_ERGO_CLONE=<clone> bash patches/train/build-train.sh 4f354391d144049160ebf0eda4fa1bab56cc85ef v6.0.9 2411 2507 2517 2518 2527 2655 2662 2664 2675 2680` |

Notes on `v6.0.9-approved-2026-10-16.patch`: #2411 and #2664 both change `CandidateGenerator.scala`; their production
diffs apply together cleanly. Merging the ten branches with `git merge` in the same order gives the same production
tree, except that #2664 then conflicts with #2411 in a test file (`CandidateGeneratorSpec.scala`, the import line of
`ErgoNodeViewSynchronizerMessages`, each adding a different message), which this patch does not carry.
