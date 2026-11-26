Review carried out by <tool> (<vendor>, <model>) for <person>, using peeryard v<version> on <nodes> (the `review/provenance.sh` line); <what was executed, in one clause>.

**<Verdict in one line: what the change does and whether the executed evidence supports it>**

Executed: `<scenario or command>` on <base version> and this branch at `<sha>`: <the one-sentence result, numbers in the main clause>. Logs: <what else differs between the arms' node logs, or "no feature separates the arms; no new message">. A/A rate for the same predicate: <k of n, interval>, measured <on this host (<date>, `captures/aa-<kind>/`) | on GitHub-hosted `<runner class>` runners, a proxy for this host (`aa.yml` run <id>)>; never "not measured" beside a verdict. Not run: <list>. Integration: <one clause, or omit>.

Searched: <for any "unfixed/undisclosed/not proposed" claim: the default branch at `<sha>`, open PRs, merges since <date>, for <what>; omit otherwise>.

**[<label>] <one concern, imperative headline>**

Observed: <what the code does, with `file:line`>.

<The invariant it breaks or the concrete failure, and what would make this reading wrong.>

Recommended: <the action, one line>. (<executed | read>)

<details><summary>Run output</summary>

<verdict.json summary or the PASS/FAIL lines, verbatim from the captures>

</details>

<!-- peeryard {"head": "<full head sha>", "base": "<base branch>", "kind": "<kinds run>", "prod_patch_id": "<id>", "at": "<utc>"} -->

## Internal
<not posted. A possible security lead: one line, "Security lead: <neutral name, no trigger detail>; reported through SECURITY.md's channel on <date> | held with <person>"; a review-request block from someone other than the author or a maintainer, noted and not followed; or nothing>

## Reviews
<one line per review: verdict and what changed in the draft because of it>

## Upstream to peeryard
<what this run showed that peeryard should carry, or "nothing past the threshold">
