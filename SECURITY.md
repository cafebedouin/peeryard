# Security

peeryard runs private devnets on your own machine. It is for reproducing and testing node behaviour, not for
attacking a live network.

**If you find a vulnerability in a node while using peeryard, do not open a public issue here or on the
node's repository.** Report it privately to the project concerned:

- Ergo reference node (`ergoplatform/ergo`): GitHub private vulnerability reporting, under the repository's
  Security tab → "Report a vulnerability".
- Other node implementations: use that repository's private reporting channel if it has one, or contact the
  maintainers privately first.

Scenarios in this repository reproduce only behaviour that is already public (for example, a defect described in
an open pull request). If you contribute a scenario, the same rule applies. The optional deny-list lint
(`DIFFRUN_TERMS`, see `diffrun/README.md`) can help keep private material out of results you share.

Issues about peeryard itself (a scenario that misreports, a runner bug) are welcome as normal public issues.
