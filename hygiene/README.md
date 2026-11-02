# hygiene: the open pull requests against the maintainers' own asks

The ergoplatform/ergo maintainers ask contributors to target the current release branch rather than `master`, to tie
each pull request to an issue, and not to open a second pull request for an issue that already has one. When they weigh
a pull request they also look at how it will merge into the two long-running lines: sub-blocks (`weak-blocks`) and
the 6.1 RocksDB line (`v5.1.0`). With a few hundred open pull requests nobody applies those asks across the whole set.
`report.py` applies them mechanically and writes one table, one row per open pull request, with a summary on top.

```
python3 hygiene/report.py [--out site/hygiene] [--git-cache DIR] [--config hygiene/branches.json] [--limit N]
```

Standard library and git 2.38 or later. A token for GitHub's GraphQL API: `GITHUB_TOKEN` or `GH_TOKEN`, otherwise
`gh auth token`; it only reads public data. Output: `<out>/hygiene.md` and `<out>/hygiene.json` (the same rows, with the
config and the timings). The clone is a full bare clone (patch-ids and merges read file contents), about 85 MB with the
pull-request heads, kept in `--git-cache` between runs.

It is a companion to the review queue (`queue/`), not part of it: the queue ranks pull requests for a reviewer; this
report checks each one against the process asks. It reuses the queue's clone-and-fetch and its rule for which issue a
description says it addresses.

**Branch roles are data.** `branches.json` names the current release branch, the full ones (accepting no new pull
requests), the dead ones, the development lines and the default branch; any other base is an *other feature branch*.
When a release branch opens or fills, edit that file, not the code. It also lists the branches the *landed* column
searches and the lines the *conflicts* column merges into.

A row is a fact about a pull request, not a ruling on it: an old pull request on `master` with no issue may still be the
right change. The report says what it found and how; whether to retarget, link, merge or close stays with the
maintainers and the author.

## Columns

| column | what it says | how it is computed |
|---|---|---|
| number, title, author, created, updated | as GitHub reports them | GraphQL `pullRequests(states: OPEN)` |
| base (role) | the base branch and its role: current, full, dead, master, line, other | `baseRefName` looked up in `branches.json` |
| issue | `formal #N`: a closing reference GitHub records (`closingIssuesReferences`: a closing keyword in the description, or a link made in the sidebar). `text #N`: no formal link, but the title or description says the pull request addresses issue N. `none`: neither. | formal: GraphQL. text: the queue's rule (`queue/build.py`, `issue_refs`): `#N` or an issue link in the title, after a lead word in the description (fixes, closes, resolves, addresses, refs, part of), or opening the description; then GitHub is asked whether N is an issue or a pull request, and only issues count |
| same issue as | the other open pull requests tied to the same issue, formally or in text | every issue with two or more open pull requests; a pull request from a release branch of the repository itself (`release_head`, e.g. `v6.0.10` into `master`) is left out, since it lists the issues of a whole release |
| landed | whether the pull request's commits are already in a branch: `all N: <branches>`, `k/N: <branch>` for some, `as one squashed commit: <branch>`, or `none`; and, when the commits are not all found, `added lines k/N: <branch>` if at least half of the lines the pull request adds are already in the same files on one branch | the commits are `merge-base(base, head)..head` with merge commits left out (the range GitHub shows). Each gets a `git patch-id --stable`; so does every non-merge commit reachable from each branch in `landed_targets` (one `git log -p` over all of them). A commit counts as landed in a branch when the branch holds a commit with the same patch-id (a cherry-pick or rebase keeps it). Separately, the patch-id of the whole diff `merge-base..head` is looked up the same way, which finds a squash merge of exactly this change. The added-lines measure: the lines the diff `merge-base..head` adds (at least 12 characters once stripped; distinct lines), less those already in the same file at the merge base, looked up in that file on each branch (`git cat-file --batch`). It sees a change that landed edited, or inside a larger commit, at the same path; the JSON has the count for every branch |
| new conflicts | the number of files that conflict when the head is merged into each line, beyond those its merge base already conflicts on, as `weak-blocks / v5.1.0` | `git merge-tree --write-tree --name-only` of the head into the line, and of the merge base into the line; the count is the difference of the two file sets. The trees merge-tree writes go to a temporary object directory, not into the clone. `?` means it could not be computed |
| CI | green, red, pending or none | the status-check rollup of the head commit (`statusCheckRollup.state`): SUCCESS is green, FAILURE or ERROR red, PENDING or EXPECTED pending, absent none |
| review | approved, changes_requested, review_required or none | GitHub's `reviewDecision`. On a branch without required reviews it stays empty (`none`) until someone reviews |
| draft | yes when GitHub marks the pull request a draft | `isDraft` |

The summary on top: counts per base role (and per branch); the pull requests with no issue, by role; the issue clusters
with each member's base, author, date and kind of link; the pull requests on a dead branch with their landed status and added lines found; the
other pull requests already in a branch, wholly (every commit) or mostly (added lines); and the **merge-ready list for the current branch**: base
is the current branch, review decision approved, CI green, not a draft, and zero new conflicts with both lines. The other
pull requests on the current branch are listed under it with what keeps each off the list.

## Known limits

- **Formal references depend on the base.** GitHub records a closing keyword ("Fixes #12") as a closing reference only
  for a pull request into the default branch; into a release branch the same words stay text unless someone links the
  issue by hand in the sidebar. That is why most pull requests on release branches show `text`, not `formal`. A malformed
  keyword (`Closes #https://...`) is also text.
- **Text references** follow the queue's rule, not every `#N` in the description: a number cited for context ("see #12",
  "like in #13") is not a tie. That rule was narrowed in the queue because counting every cited number grouped unrelated
  pull requests. The cost is the other way round: a description that names its issue only in the middle of a sentence
  ("this solves the problem from #12") is reported as `none`.
- **Clusters are by issue number only.** Two pull requests on one issue may be alternatives, parts of a series by one
  author, or a fix and a follow-up; the cluster says they share the issue, nothing more. The queue's *same issue* view is
  narrower (different authors, overlapping production files) and its *same change* view finds identical diffs with no
  issue at all.
- **Landed by patch-id** finds a commit cherry-picked or rebased unchanged, and a squash merge whose diff equals the
  whole pull request. It misses a change that landed edited (a conflict resolved, a line reworded, a squash that also
  took other commits) or split differently; those read `none` or `some`. A `some` can also mean the pull request carries
  commits of another pull request that has landed. An empty commit has no patch-id and is not counted. The added-lines
  measure covers part of that gap but is a heuristic: it matches lines, not their order or place, misses a file that
  was moved or renamed, and a branch that carries commits of other pull requests reads as mostly landed. Treat
  `added lines` as a pointer to read the branch, not as proof.
- **The range is GitHub's.** A pull request whose branch merged a newer upstream branch carries those commits in its
  range, and they show as landed. A base branch deleted since the pull request was opened is replaced by the base
  commit GitHub recorded.
- **New conflicts are file counts.** A file that already conflicts at the merge base is not counted again, even if the
  pull request makes the conflict larger; a file that merges cleanly can still break the build. The count says how many
  files a maintainer would resolve by hand, not how hard.
- **CI and review state are GitHub's** at the time of the run: a rollup for a head whose checks have not started is
  `none`, and the review decision of a branch without required reviews is empty until someone reviews.
- **A snapshot.** Each run reads the live state; nothing is kept between runs except the clone.

## Runtime

A full run over 283 open pull requests (2026-11-02, a 12-thread desktop under WSL2): **71 s from an empty cache**, 61 s
with the clone kept. Of that, about 22 s is GitHub (six GraphQL pages of 50 pull requests and one query for the kinds
of the referenced numbers: seven requests in all, well inside any rate limit), 11 s the clone and fetch (1 s when
kept), 13 to 16 s the patch-ids and added lines (one `git log -p` over every branch and head), and about 20 s the
merges (two lines, plus each merge base once). Peak memory about 210 MB. A GitHub-hosted runner has not run it yet; with
checkout it should take a few minutes at most, and the workflow's timeout is 20 minutes. Weekly, that is well under an
hour of runner time a year.

## The workflow

`.github/workflows/hygiene.yml` runs the report weekly on a GitHub-hosted runner and keeps the output as an artifact for
30 days, with the summary on the run page. It is committed **off**: the scheduled job is skipped (no runner minutes)
unless the repository variable `HYGIENE_ENABLED` is `true`; a manual dispatch runs regardless.

## Tests

`tests/hygiene_test.py` (git only, no network): base roles, issue clusters with a release-branch pull request left out,
landed by cherry-pick and by squash, and a merge base's own conflict not counted as new.
