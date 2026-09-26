# diag/: reading what the runs left behind

Four tools over the logs a run keeps. They name candidates; they do not prove causes. A candidate becomes a claim
when a test that forces the named state passes and fails as predicted, and the run a public claim rests on is made
on a GitHub-hosted runner (a development machine discovers; the runs a claim rests on are made where anyone can re-run them).
All four are standard-library Python and have tests in `tests/` (wired into `tests/tooling.sh` and CI).

| tool | question | input | output |
|---|---|---|---|
| `diagnose.py` | why did this run miss its goal? | one run's sampled `/info` (`samples.jsonl`) | a named cause (node down, stalled, lighter fork not switching, ...) in `verdict.json` |
| `features.py` | which per-run feature separates the runs that failed from those that passed? | run dirs + outcome labels (or each run's verdict line) | features ranked by separation (perfect split first, then AUC), with ranges per outcome |
| `sweep.py` | which runs look unlike the others, or show something never seen before? | a tree of run dirs, no labels; optionally earlier runs as a baseline | per run: rare messages, count outliers, feature outliers; with `--baseline`: new messages, new transitions, new co-occurrences, features outside the known range |
| `logmap.py` | which line of the node's source wrote this log line? | a node source checkout | an index of `log.<level>(...)` calls; `--source` on `features.py` and `sweep.py` names the code behind each finding |

## How they fit

1. A batch of runs fails some of the time. `diagnose.py` has already named each failure's end state.
2. **Known split** (you can label the runs): `features.py --labels runs.tsv` ranks the features that separate
   them. Retro-check: blind, it re-found the two discriminators found by hand on 2026-09-25 (a follower's header
   lead at stop, 6-7 vs 0-5, behind a CI hang; a chain switch's first step, 13-25 vs 32-47, behind lost
   mempool transactions).
3. **No split yet, or looking for anything new**: `sweep.py <runs> --baseline <earlier runs>` lists what these runs
   show that none before did. Read every item and keep or discard it; a checked batch can join the baseline, so
   the next sweep shows only what is new again. Novelty is a search: the list is candidates, not findings.
   Within one batch (no baseline) the sweep ranks anomalies instead; a failure mode that hits a large share of
   runs is not rare, so label the runs and use `features.py` for it.
4. Add `--source <node checkout>` to either tool to see the code line behind each message or feature
   (about 92% of the templates in a 60-run corpus map to one line; the rest are Akka's own logs or messages built
   indirectly).

```
python3 diag/features.py --labels runs.tsv --target hung --source ~/src/ergo
python3 diag/sweep.py new-runs/ --baseline old-runs/ --source ~/src/ergo
python3 diag/logmap.py find ~/src/ergo '10:04:05.505 WARN  [x] o.e.n.ErgoModifiersCache - Modifier ab.. is permanently invalid ...'
```

## Limits

- Log-derived features depend on the node's log lines; a renamed message silently drops a feature. `logmap.py`
  run against the jar's source catches that (the line stops mapping).
- A run dir is any directory holding `node_<X>.log(.gz)` or `...-node<NN>-<container>.log`; a log directory named
  `ci-logs`, `logs` or `out` stands for its parent. Several logs for one node (a restart per container) are keyed
  `<node>#1`, `<node>#2` by first timestamp.
- Rates from a batch are bounds, not verdicts: report "0 of 20, rate below ~14% at 95%", and pre-register the n.
