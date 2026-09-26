# stack: which merge shrinks the most review

When several open PRs are stacked on a shared base, each reviewer re-reads that base in every PR, and each PR
needs its own rebase. `stack_order.py` measures that from git alone and says which merge removes the most
review surface from the others.

```
# the clone needs the PR heads as refs:
git clone --bare https://github.com/ergoplatform/ergo ergo.git
for n in 2366 2367 2368 2369 2370 2500 2502 2503 2504 2505 2506; do
  git -C ergo.git fetch -q origin "+refs/pull/$n/head:refs/pull/$n"; done

# pairwise carry + score:
python3 stack_order.py --repo ergo.git --base weak-blocks --prs 2366 2367 ... 2506

# smallest carriers (credit each shared block to one PR, rank by projected reduction):
python3 stack_order.py --repo ergo.git --base weak-blocks --roots --prs 2366 2367 ... 2506
```

## What it computes
- **surface(PR)** — added + deleted lines in the PR's diff against its base branch. With several merge bases
  (criss-cross master merges), it uses the one giving the smallest diff, which is usually the diff GitHub shows.
- **overlap** — a `-U0` diff hunk of ≥2 changed lines whose exact signed-line text appears in more than one PR
  in the same file. Matching is by text, not position: the same lines changed at two different places count as
  shared (which can overcount), and near-copies that differ by one line are missed (which undercounts). So the
  figure is an estimate under exact matching, not a bound in either direction; the "lower bound" in
  `stack_order.py`'s own docstring considers only the undercount. It reports the same changed lines appearing in both diffs, not that one PR
  authored them. The pairwise view (`score`) uses hunk containment (X's hunk inside a hunk of Y); `--roots`
  groups by exact hunk equality.
- **`--roots`** — groups shared hunks by the set of PRs that carry them, credits each group to the smallest PR
  that contains all of it (the *smallest carrier*, see Known issue), and ranks groups by `lines × (owners − 1)`
  = review lines removed from the others once the text lands once and they rebase. It also prints, per PR, its
  own changed lines vs the duplicated-elsewhere lines, and whether it merges cleanly into the base: `clean` or
  `conflict` with git 2.38 or later (`merge-tree --write-tree`). On older git the legacy `merge-tree` form it
  falls back to cannot see these conflicts, so it reports `clean` (or `unknown` when git fails): treat the
  status as unchecked there.

## Example (ergoplatform/ergo weak-blocks at `90a129733`, 11 open PRs)
`example-weak-blocks.txt` is the tool's `--roots` output. One 1,788-line candidate-generation/mining text is
shared by 10 of the 11 PRs; landing it once takes ~1,788 lines out of each of the others. The closing line names
#2369 as the smallest *carrier* of that text; #2369 conflicts with the base itself, so it is a candidate to rebase
and land first, not a review target.

## Limits
Lines are review surface, not effort — a test counts the same as production code. It says nothing about whether
any PR should merge, only how much reviewing the same thing twice costs. It reads git only; it builds and runs
nothing.

**Known issue:** a block is keyed by the exact set of PRs carrying it, so every
owner holds the whole block by construction. The `root` is therefore the *smallest carrier* of the block, not
its origin or a dependency; the "extract into its own PR" case can never be reported under this grouping. Read
the output as **review triage** (which PRs re-review the same text, and which carrier is cheapest to land
first), not as merge-order authority. Semantic ownership and ancestry are invisible from hunks; the honest
names for the outputs are *textual overlap*, *smallest carrier* and *projected reduction*, and a measured
mode (land X synthetically, rebase each Y, diff what remains) is the planned fix. See the Roadmap comment at
the foot of `stack_order.py`.

## Related tools
Stacked-diff tools (Graphite, Sapling, ghstack, spr, git-branchless, Gerrit relation chains) manage a stack
that was declared as one; this tool looks for shared text across PRs that were never declared a stack.
Duplicate-PR detectors look for two PRs that make the same whole change; this looks for partial text shared by
many. The "Pull Request Tracker" GitHub Action checks conflicts and similar hunks across open PRs and is the
closest tool on that axis. `git patch-id` / `git cherry` work at commit level. Merge queues (Bors, Mergify,
GitHub's, Zuul) order merges to keep the base green rather than to reduce review surface.
