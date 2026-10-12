# Contributing

peeryard is EXPERIMENTAL and small; contributions that keep it that way are welcome.

**The one rule.** Before adding a technique, ask: does it expose a specific weakness, and does releasing it help
secure the network more than it helps someone attack it? Testing honest nodes is often adversarial in form (checking
that they guard correctly), and that alone does not keep it out.
- **In scope:** what anyone can already do with standard node and wallet software, used to check that nodes behave:
  delay, loss, partitions, crashes and restarts, mining control, honest votes, different versions side by side,
  payments, conflicting spends from one wallet on two nodes, honest storage-rent collection.
- **Not here until publicly disclosed:** anything that demonstrates a specific weakness, until it is fixed or disclosed
  in a public issue or pull request. A scenario that reproduces a defect names the public issue or pull request it
  reproduces; a defect that is not public yet goes where `SECURITY.md` says.
- **A public pull request is public.** What an open pull request discloses can be tested and discussed openly here,
  and the useful thing to bring to it is evidence that steers it toward the broader, more secure fix. Anything you
  know beyond what it discloses stays private.
- **Not here:** tooling whose main gain is offensive capability beyond standard software: crafted or malformed
  messages, wire fuzzers, lying or withholding peers, eclipse or peer-slot tooling.

Where this line sits will move as node security and attacker tooling change; a contribution that is close to it
says in its description which side it is on and why.

**Before a pull request**
- `shellcheck -x` on every script you touched (the repository's `.shellcheckrc` lists the deliberate
  exceptions), and `bash -n`.
- The no-node self-tests: `T=$(mktemp -d) bash tests/sequential.sh`, `... tests/lint.sh`, `... tests/precheck.sh`, `... tests/phases.sh`, `... tests/tooling.sh`, `... tests/indexer_diff.sh`;
  each exits non-zero on a `MISMATCH`. `T` must be a fresh empty directory: each test deletes it first.
- If you changed a scenario, a precheck or the rig: one real run of what you changed, and its output in the PR
  (the rig's `effective.json` and the runner's `table.txt` are the evidence, not a description of them).
- If you changed `tests/stop_rule_sim.py` or a manifest's `n`, `max_n`, `stop_when` or `expect`: re-run the
  simulation and update the table in `diffrun/README.md` from its output.

**Adding a scenario.** Follow the contract in `diffrun/README.md` (argv[1] is the jar, `WORKDIR` and the
manifest's `env` come from the environment, exactly one `RESULT_JSON` line, exit 3 with an `INCONCLUSIVE:` line
on setup failure), add a manifest with `tier: public`, add a row to `diffrun/scenarios/FIT.md` saying which
changes it can observe, and cite the public issue or PR. Prefer the rig-hook template
(`diffrun/scenarios/lib/rig-scenario.sh`, as `interop`, `txload` and `bootstrap-modes` use it): a topology and a
hook instead of a copy of the rig's namespace code.

**Adding a rig example.** Start from [`rig/PHASES.md`](rig/PHASES.md): a new scenario is a topology file and a
hook written as phases (one line per step, ending in a `pass` rule), unless it needs its own observation, a log, a
fixture or an outside oracle; then it is a shell hook that sets `rig_verdict=PASS` or `FAIL`
([`rig/HOOK_API.md`](rig/HOOK_API.md)). Either way, list it in `rig/README.md`'s table with one line on what it checks.

**Style.** Plain bash (4.4 or later), `jq`, POSIX tools; no new runtime dependencies without a reason in the PR. Say what a
number means and where it came from. Prefer a failing check to a silent fallback.
