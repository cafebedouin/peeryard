# ci-red: recount three it tests' outcomes from upstream CI job logs

A recount of how often three ergo `it` tests fail in upstream CI, by pool of jobs, read from the job logs
themselves. It backs the base rates quoted for the red `it` jobs on approved v6.0.9 pull requests
(ergoplatform/ergo #2719, 2026-10-16). The tests, by their ScalaTest names:

- "Fork resolution after isolated mining" (`ForkResolutionSpec`, FR)
- "Deep rollback handling" (`DeepRollBackSpec`, DRB)
- "Utxo state nodes synchronisation (5 blocks)" (`UtxoStateNodesSyncSpec`, USS)

## Run

Needs bash, `gh` (authenticated; the logs are public), grep, sed, awk. Touches nothing but stdout; about 2 to 5 s
per job. Upstream keeps job logs for 90 days, so from about 2027-01-10 the jobs print `log unavailable`.

```
bash recount.sh jobs_current_code.txt          # pools "base" and "near"
bash recount.sh jobs_strict_release_trees.txt  # pools "strict" and "release-trees"
```

Each prints one line per job (job, pool, tested base, the three outcomes), then one `TOTAL` line per pool and
`RECOUNT done`. The witnessed outputs are `recount_output.txt` and `recount_strict_output.txt`; their `TOTAL`
lines:

```
TOTAL base jobs=22 FR=10/22 DRB=3/22 USS=3/22
TOTAL near jobs=54 FR=28/54 DRB=7/54 USS=3/54
TOTAL release-trees jobs=10 FR=2/10 DRB=2/10 USS=2/10
TOTAL strict jobs=13 FR=3/13 DRB=2/13 USS=2/13
```

A count that differs from these is a finding against the table they back. (The order of the `TOTAL` lines is
sorted; the per-job lines follow the input order.)

## Which jobs, and the pool labels

The job lists are the input; the script does not recompute the labels. "Current code" = upstream "Run it node
tests" jobs, 2026-10-12..16: PR jobs whose checkout line (`Merge <head> into <base>`) tested v6.0.9 at
`d95c4fd2a` or `4f354391d`, or the v6.0.8 branch after #2649 and #2650 at `3c6df4b17` or `3343181150`; plus the
release branches' own runs at heads containing both (#2719 at `d95c4fd2a`, `16f946e1e`, `4f354391d`; #2640 at
`76397baab`, `3c6df4b17`, `3343181150`, `16c64d1e5`).

A PR's class comes from `git diff --name-only <merge base of tested base and head> <head>`:

- **near** if any changed path matches: `src/it/*`; `src/main/scala/org/ergoplatform/network/*`;
  `src/main/scala/scorex/core/network/*`; `src/main/scala/org/ergoplatform/nodeView/ErgoNodeViewHolder.scala`;
  `*/nodeView/history/*` except `*/nodeView/history/extra/*`; `*/nodeView/state/*`; `*/mining/*`;
  `src/main/resources/*.conf` (shell-style globs, `*` crossing `/`).
- **far** otherwise.
- `base` in `jobs_current_code.txt` = far PRs plus the release branches' own runs; `near` = the rest.
- `strict` in `jobs_strict_release_trees.txt` = as `base`, but a far PR also must change no `src/main` file other
  than under `nodeView/history/extra/` or `openapi.yaml`. It drops mempool, modifier-cache, block and wallet PRs
  from `base`.
- `release-trees` = the release branches' own runs plus the runs of the 6.0.8 release trees on master: #2718's
  run (the version bump, `f5c8868ad` into `e440ecae8`) and master's pushes of `e440ecae8` and `c1a69f65d`.

`classify.py` is the script that applied the near/far rule. Its input is a table built from the Actions API
(columns: run id, created, head owner, head branch, head sha, tested base, epoch, PR, PR base), which is not
included; with any table of that shape and a clone that has both branches it reproduces the class column.

## Files

| file | sha256 |
|---|---|
| `recount.sh` | `5c0654bdf1e8a00e66779f66f8319002e7f10c865b5a09e1795ca6c9e77051ae` |
| `jobs_current_code.txt` | `600c50a34b0cecd5f3a4cfcf5359c9226dbf22a6af17b9bc7ec11aea969625f9` |
| `jobs_strict_release_trees.txt` | `d6592fe5d2faf3c840f050505574ffd95c37384ad82e7809c5990ec13f184e0e` |
| `recount_output.txt` | `f2584c8e733ca6f6ac853deb16b6c5d5680ba3c9b40af2e1d505cf18738270a0` |
| `recount_strict_output.txt` | `4bc7043b60f64b678cf812d470741f21d9c88484134b54b257e65c3534950ed6` |
| `classify.py` | `6106f4ba9315aa4d6f50e4d3af27d511e9a79aa84d712aa9504b8c4d325f7244` |

These are the bytes that ran. `.shellcheckrc` here disables one style note (SC2001) for `recount.sh` rather than
edit the script after the run.
