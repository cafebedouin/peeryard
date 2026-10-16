# Composites of open pull requests ("trains"), for patch mode

Each file is several ergoplatform/ergo pull requests' production diffs applied in order on one line commit, as one
patch: the node a branch becomes if those PRs merge. It is **a composite of public PRs, not a release**, and nothing
here is proposed upstream as a change of its own. Run one with pr-scenario.yml's patch mode (`extra_patch` with `pr`
empty; base arm = the line, candidate = the line + the patch) or with `review/release-check.sh dispatch --patch <file>
--line <commit> --ref <the branch carrying the file>`.

Made with `build-train.sh` (each PR's `<base branch>...<head>` diff over `src/main ergo-core/src/main
ergo-wallet/src/main avldb/src/main`, the same dirs pr-scenario.yml builds from, applied with `git apply --index` and
committed in the order given; the file is the diff from the line to the last commit). A diff that applies is not a
diff that compiles: compile the composite (and each PR alone on the line) before dispatching it. When a PR needs a
change on the newer line that its own diff does not carry, the composite takes a **named fix-up** (`fixups/`, given to
`build-train.sh` as `@<file>`); the composite is then "the PRs + the named fix-ups" and says so wherever it is cited.
A file is never edited: a PR that moves gets a new file with a new date. Re-derive one with the command in its row
and compare the sha256.

| file | line | PRs, in apply order (head), and fix-ups | sha256 | made with |
|---|---|---|---|---|
| `v6.0.9-approved-fixup-2026-10-16.patch` | v6.0.9 tip `4f354391d144049160ebf0eda4fa1bab56cc85ef` | #2411 `bdc9165d`, #2507 `52fa2b37`, #2517 `b8892a59`, #2518 `114add1c`, #2527 `7bd94a6e`, #2655 `6a3ed687`, #2662 `23659bf4`, #2664 `f95af817`, #2675 `626e5ca8` + fix-up `fixups/2675-import-ModifierSemanticValidity.patch` (sha256 `180eb0d1…`), #2680 `d4019b69` (the PRs on v6.0.9 that were approved, mergeable and green on 2026-10-16; 12 files, +361 -151) | `2b5dad753dee4dc5320a4422fd736fec32744c30ea7a35b8fc8bd4fe06ae3ce2` | `DIFFRUN_ERGO_CLONE=<clone> bash patches/train/build-train.sh 4f354391d144049160ebf0eda4fa1bab56cc85ef v6.0.9 2411 2507 2517 2518 2527 2655 2662 2664 2675 @patches/train/fixups/2675-import-ModifierSemanticValidity.patch 2680` |

Notes on `v6.0.9-approved-fixup-2026-10-16.patch`:
- **The fix-up.** #2675's diff applies on v6.0.9 but does not compile there (`ErgoHistory.scala:256:14: not found: value
  ModifierSemanticValidity`): its head imports `org.ergoplatform.consensus.{ModifierSemanticValidity, ProgressInfo}`,
  but v6.0.9 (and v6.0.8) narrowed that import to `ProgressInfo` in `b0b2d342f` (2026-10-11), after the PR branched
  and after its last CI run (2026-10-10). The fix-up restores the import, one line. With it, #2675 alone and the
  composite compile; without it, neither does (sbt `compile`, JDK 8, main sources; the other nine compile alone on the
  tip). The first version of this file, `v6.0.9-approved-2026-10-16.patch` (sha256 `4685e063…`, no fix-up), was
  removed for that reason before any run used it.
- #2411 and #2664 both change `CandidateGenerator.scala`; their production diffs apply together cleanly. Merging the
  ten branches with `git merge` in the same order gives the same production tree as the PRs without the fix-up,
  except that #2664 then conflicts with #2411 in a test file (`CandidateGeneratorSpec.scala`, the import line of
  `ErgoNodeViewSynchronizerMessages`, each adding a different message), which this patch does not carry.
