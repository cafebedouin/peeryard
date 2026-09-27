Review carried out by <tool> (<vendor>, <model>) for <person>, using peeryard v<version> on <nodes> (the `review/provenance.sh` line); <what was executed, in one clause: scenario, pairs, versions>.

**<Verdict in one line: what the change does and whether the executed evidence supports it>**

Executed: `<scenario or command>` on <base version> and this branch at `<sha>`: <the one-sentence result, numbers in the main clause>. Logs: <what else differs between the arms' node logs: the features that separate them and the messages new on the candidate (logab), or "no feature separates the arms; no new message">. The release's own rate on this host for the same predicate: <A/A figure, from `diffrun/examples/` or a run on this host>. Not run: <what the fit table skipped and why; the revert check; other platforms>.

**[<label>] <one concern, imperative headline>**

Observed: <what the code does, with `file:line`>.

<The invariant it breaks or the concrete failure, and what would make this reading wrong.>

Recommended: <the action, one line>. (<executed | read>)

<Repeat the labelled block once per concern; one concern per block. Nothing else in the body. An Integration item
(vehicle, duplicate, stray files) never stands beside a correctness finding as its own block: fold it into the
verdict paragraph as one clause, and keep the labelled blocks for correctness (GUIDE.md).>

<details><summary>Run output</summary>

<verdict.json summary or the PASS/FAIL lines, verbatim from the captures>

</details>
