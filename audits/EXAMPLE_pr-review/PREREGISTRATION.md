# PREREGISTRATION — pr-<N>: <one line: what the pull request claims>

Frozen before any run. Recon so far: the PR thread read; `review/footprint.sh` output (production files, FIT rows).

## Claim tested, what counts against it, what a reviewer without the tool finds
- **Claim:** <e.g. "the candidate makes a lighter-fork follower switch where the release does not" (fork-convergence)>.
- **Counts against it:** <e.g. "a NULL verdict (the release switched in every base run: the effect is not reproduced here) or an AGAINST (a candidate run did not switch)">.
- **Without the tool:** <e.g. "a code read of the synchronizer change would say whether the cache is bypassed; it could not say whether the node switches">.

## Subject
Repository <owner/repo>, pull request #<N> at <head sha>, merge base <mb> with its base branch (`merges@<mb>` from
`review/pick.sh`); base built with `diffrun/build.sh <mb>` (jar sha256 <prefix>), candidate with
`diffrun/build.sh <mb> <mb>...pr-<N>` (patch sha256 <prefix>); the release's own rate from an A/A run of
<release jar, sha256 prefix> on this host. Nothing outside `audits/` and the jar cache is written.

## Method
1. `review/pick.sh` and `review/footprint.sh` → `captures/footprint.txt`.
2. `diffrun/run.sh diffrun/scenarios/<kind>.json …` → `captures/<kind>/` (verdict.json, table.txt, per-run dirs).
3. <further kinds>.
4. The report from `review/templates/review.md`; three reviews; `review/post.sh`.
