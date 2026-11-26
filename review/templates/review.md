Review carried out by <tool> (<vendor>, <model>) for <person>, using peeryard v<version> on <nodes> (the `review/provenance.sh` line); <what was executed, in one clause: scenario, pairs, versions>.

**<Verdict in one line: what the change does and whether the executed evidence supports it>**

Executed: `<scenario or command>` on <base version> and this branch at `<sha>`: <the one-sentence result, numbers in the main clause>. Logs: <what else differs between the arms' node logs: the features that separate them and the messages new on the candidate (logab), or "no feature separates the arms; no new message">. A/A rate for the same predicate: <k of n, interval>, measured <on this host (<date>, the A/A capture) | on GitHub-hosted `<runner class>` runners, a proxy for this host (`aa.yml` run <id>)>. Not run: <what the fit table skipped and why; the revert check; other platforms>. Integration: <one clause: vehicle, duplicate hunks, scope, stray or agent-instruction files by path; omit the sentence when there is none>.

Searched: <only when the text says something is unfixed, undisclosed or not proposed upstream: the default branch at `<sha>`, the open pull requests and the merges since <date>, for <what>; omit the line otherwise>.

**[<label>] <one concern, imperative headline>**

Observed: <what the code does, with `file:line`>.

<The invariant it breaks or the concrete failure, and what would make this reading wrong.>

Recommended: <the action, one line>. (<executed | read>)

<Repeat the labelled block once per correctness concern; one concern per block. Nothing else in the body. An Integration
item never gets a labelled block in a review body: it is the one `Integration:` clause above (GUIDE.md, Labels). A
verdict is quoted only with its A/A rate, named by where it was measured; when no A/A for that predicate exists, run one
before quoting the verdict ("not measured" never stands beside one). A possible security problem never appears above
`## Internal`.>

<details><summary>Run output</summary>

<verdict.json summary or the PASS/FAIL lines, verbatim from the captures>

</details>

<!-- peeryard {"head": "<full head sha>", "base": "<base branch>", "kind": "<kinds run>", "prod_patch_id": "<id>", "at": "<utc>"} -->
<!-- the line above is written by `python3 queue/mark.py --pr N --kind <kinds>`; keep it: the queue page and review/prior.sh find and carry the review by it -->

## Internal
<Not posted: review/post.sh posts only the text above this heading. A possible security lead in a released node is written
here and nowhere else, as one line per lead: "Security lead: <a neutral name, no trigger detail: no input, no file:line, no
interleaving>; reported through SECURITY.md's channel (ergoplatform/ergo: the repository's private vulnerability reporting)
on <date> | held with <person> until it is worked to a fix and its route is decided". The route is judged on the fix, not
the lead (AGENTS.md): a fix that stands on its own correctness argument can go out as an ordinary point in a later
review. Omit the heading's content when there is no lead; keep the heading.>

## Reviews
<one line per review (derivation, fidelity, maintainer): its verdict and what changed in the draft because of it>

## Upstream to peeryard
<the closing gate (GATES.md 4): what this run showed that peeryard should carry, or "nothing past the threshold">
