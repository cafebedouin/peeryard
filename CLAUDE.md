# CLAUDE.md

Read `AGENTS.md` first; it is the working guide for this repo. This file adds one standing caution.

## GitHub Actions usage

GitHub's free Actions minutes for public repos are subject to a usage check. It can switch a repository's workflows
off, and it acts with a lag. On 2026-10-09 it disabled workflows on the related fork `cafebedouin/ergo` about twelve
days after a single day of ~820 dispatched integration runs (~290 runner-hours). This repo runs on the same account.

- Before dispatching (`sweep`, `aa`, `patch-compare`, `pr-scenario`, `matrix-relay`, `queue`), size the batch
  (runs × jobs × minutes) and say it. Keep to tens of runs a day; pace large counted batches across days.
- The account has 20 concurrent jobs shared across all its repos. A full matrix here queues every other repo's runs.
- If a dispatch returns HTTP 422 "Actions has been disabled for this repository" while the permissions API still
  says enabled, read the repo's Actions tab banner before assuming a rate limit. Re-enabling is the operator's call.
