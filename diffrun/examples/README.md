# Example outputs

Finished runs, as `run.sh` wrote them (`verdict.json` and `table.txt`; the private `run_meta.json` is never
part of an example). They show what a result looks like before you spend an hour producing one.

| directory | what it is |
|---|---|
| `fork-convergence-pr2511-hosted/` | an example of the hosted workflow, **not a headline result**: a run on a GitHub-hosted `ubuntu-24.04` runner with base = the upstream-built 6.0.6 release jar and candidate = v6.0.6 plus the production diff of ergoplatform/ergo#2511, built locally on the runner. The pair differs in two ways (the patch and the toolchain), and the only A/A calibration comes from a different host (one development host, below), so the A/A rate cannot be read against it. 8 pairs, 16/16 VALID, stopped by the sequential rule, verdict **SUPPORTS**: the base failed to switch in 2 of 8 runs, the candidate switched in 8 of 8. Note the `warn_S` metric: 15 in exactly the two non-switching base runs, 0 in every switching run. The `fork_height` values below the synced prefix (9 in candidate-1 and candidate-2) came from a since-fixed bug in that metric (an empty REST reply was read as a mismatch); the `switched` verdicts do not depend on it. |
| `sibling-fork-aa-control/` | an **A/A control**: the same released 6.0.6 jar in both roles, one fixed pair. It predates the scenario's current candidate predicate (`D_confirmed`): its table judges `D_total`, so it is not an A/A rate for that predicate. The verdict is not evidence about any change (the table says so); the runs show the metrics a release produces on its own. |
| `fork-convergence-aa-6.0.6/` | an **A/A calibration** of `fork-convergence`: the released 6.0.6 jar in both roles, on one development host, 8 pairs (sequential rule, stopped by rule), 16/16 VALID, verdict **AGAINST** — not evidence about any change: the base switched in 5 of 8 valid runs and the candidate (the same jar) in 3 of 8. This is the release's own switch rate under this scenario on one development host, the null a before/after pair on the same host is read against. |
| `interop-aa-6.0.6/` | **A/A**, the released 6.0.6 jar in both roles, one pair, on one development host: VALID/VALID, `follow_ab`/`follow_ba` true both ways. The base line for an agreement scenario is "both roles agree"; a base-versus-candidate `interop` pair is read against it. |
| `txload-aa-6.0.6/` | **A/A**, same host: VALID/VALID, 10 of 10 payments accepted and confirmed in both roles, 17 transactions in blocks. |
| `bootstrap-modes-aa-6.0.6/` | **A/A**, same host: VALID/VALID, settled, state roots agree, pruning visible, at heights 148 and 150. |

A verdict's `provenance` names the scenario script's hash and the runner revision it came from (`unknown`
when `run.sh` ran from a plain copy of the tree rather than a git checkout, as the A/A control did); these
examples were produced by earlier revisions of this tree and are kept as they were written.

A current runner also records the host in `provenance.host` (kernel, cpus, memory; no hostname): an A/A rate is a
per-host number and is only comparable with a run on the same host. The examples above predate that field. The
three agreement-scenario A/A examples (`interop`, `txload`, `bootstrap-modes`) were rendered before a wording fix
in the runner, so their `table.txt` still says "the base showed the effect and the candidate did not";
`verdict.json` is the canonical file, and a current runner renders that verdict as "both roles met the same expectation: an agreement scenario,
not a before/after difference".
