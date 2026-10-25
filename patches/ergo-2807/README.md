# A variant of ergoplatform/ergo#2807, as a patch on its head

`git diff <PR head> <variant> -- src/main` against head `110ea35b7af2ccdc2c21c7682a4deaa39c995e15`, for the
`pr-scenario` workflow's `extra_patch` input (candidate only: the candidate becomes base + PR diff + this patch, the base
arm stays the plain line). Measured with `diffrun/scenarios/matrix-zero-id.json`.

| file | change | what it is for |
|---|---|---|
| `view-holder-only.patch` | reverts the PR's `ErgoNodeViewSynchronizer` hunks, keeping its `ErgoNodeViewHolder` change | reads whether the view-holder change alone removes the requests for header 0…0; the candidate's production diff is then exactly the PR's `ErgoNodeViewHolder.scala` hunks |
