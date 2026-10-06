# health fixtures

`p1-v3-1/` and `p1-v4-1/` reproduce, in the layout of a patch-compare run artifact (`errors-node_<X>.txt`, the
workflow's `uniq -c` of each node's ERROR lines), the ERROR-line counts that the pool job of
[patch-compare run 37306440981](https://github.com/cafebedouin/peeryard/actions/runs/37306440981) printed for its
`p1 v3` and `p1 v4` runs (one run each, so the pooled counts are that run's). The pool job sums over nodes, so each
fixture puts the run's counts under one node, `A`; the per-node split is in the artifacts themselves, which
`.github/workflows/health-recheck.yml` reads. Those two runs are the positive control (p1-v3: the mining thread's
supervisor restarted it 230779 times under `MATRIX-COMPAT: PASS`) and the negative control (p1-v4, same dispatch: no
restart line) of `diag/health.py`.
