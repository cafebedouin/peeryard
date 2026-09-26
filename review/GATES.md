# Gates: what must hold before a comment, a review, an issue or a pull request leaves the machine

Three gates, each catching a different failure; none substitutes for another. They apply to text a person
posts and to text an agent prepared for them.

1. **Independent re-derivation.** Every load-bearing claim is re-derived from the pinned source by a reviewer
   who read the code first, not the draft (a reviewer who reads the draft and then "checks" it confirms the
   author). Enumerate the claims, separate them from framing, re-derive each with a capture, and confirm every
   search pattern matches a known hit before trusting an empty result. Write "verified / couldn't verify /
   would cut" first. A fact a reviewer introduces is itself a load-bearing claim and gets the same check.
   In this frame: `seats/derivation.md` (blind, code first), `seats/fidelity.md` (every sentence against the
   captures and the rules), `seats/maintainer.md` (would the recipient accept it, right vehicle and scope).
2. **Search the upstream frontier, not the pinned tag.** Before claiming anything is undisclosed, unfixed or
   unproposed, search the default branch, open pull requests and recent merges. A pin licenses "present in
   this release", never "unknown upstream". Cite the searched scope.
3. **Explicit human go on the final text.** A review can verify every claim and still miss that it is the
   wrong thing to send, or that the scope drifted. The person's go on that specific final text is the last
   gate; "review passed" is necessary, never sufficient. `post.sh` asks for it and saves what was posted.

And, before all three: **private routing.** Anything that could be a security problem in a released version
goes through the project's private channel (`SECURITY.md`), never to a public thread. When unsure, private.

A draft that got longer after review is a reason to check for scope drift, not a sign of progress.

4. **Closing gate: what belongs upstream in peeryard?** After the review is posted, or the decision not to
   post, the model is asked one more question: did this run produce anything peeryard itself should carry:
   a recipe or scenario that did not exist, a fix to a script or an oracle, a node behaviour the docs should
   state, a run card that was wrong. The threshold is novelty, a pattern seen twice, or a fix: not "I touched
   it". The answer is written into the run's `REPORT.md` under *Upstream to peeryard*; anything past the
   threshold becomes a pull request to peeryard only through gates 1–3 again and the person's separate
   approval, never as a side effect of the review.
