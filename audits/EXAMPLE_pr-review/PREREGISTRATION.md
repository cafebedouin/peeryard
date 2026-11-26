# PREREGISTRATION — pr-<N>: <one line: what the pull request claims>

Written after the pick, the footprint and the thread read, and frozen before any run. Recon so far: the PR thread read
(existing reviews; a `review-request` block, and whether its author is the PR's author or a maintainer);
`review/footprint.sh` output (production files, FIT rows). Kinds chosen from that read: <kinds, and why each>.

## Claim tested, what counts against it, what a reviewer without the tool finds
- **Claim:** <e.g. "the candidate makes a lighter-fork follower switch where the release does not" (fork-convergence)>.
- **Counts against it:** <e.g. "a NULL verdict (the release switched in every base run: the effect is not reproduced here) or an AGAINST (a candidate run did not switch)">.
- **Without the tool:** <e.g. "a code read of the synchronizer change would say whether the cache is bypassed; it could not say whether the node switches">.

## Subject
Repository <owner/repo>, pull request #<N> at <head sha>, merge base <mb> with its base branch (`merges@<mb>` from
`review/pick.sh`); base built with `diffrun/build.sh <mb>` (jar sha256 <prefix>), candidate with
`diffrun/build.sh <mb> <mb>...pr-<N>` (patch sha256 <prefix>); the A/A rate for each quoted predicate from <an A/A
run of <release jar, sha256 prefix> on this host | the `aa.yml` run <id> on GitHub-hosted `<runner class>` runners, a
proxy for this host>. Nothing outside `audits/` and the jar cache is written.

## Method
1. `review/pick.sh` and `review/footprint.sh` → `captures/footprint.txt` (before this file; recorded here).
2. `review/revert-check.sh --pr <N> --out audits/<date>_pr-<N>/captures/revert-check` → `captures/revert-check/`.
3. `diffrun/run.sh diffrun/scenarios/<kind>.json …` → `captures/<kind>/` (verdict.json, table.txt, per-run dirs).
4. <further kinds>.
5. The report from `review/templates/review.md`; three reviews; the person runs `review/post.sh`.
