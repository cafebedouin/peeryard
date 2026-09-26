# Contributing

peeryard is EXPERIMENTAL and small; contributions that keep it that way are welcome.

**The one rule.** peeryard creates ordinary network conditions for honest nodes. No attack tooling: no crafted
or malformed messages, no fuzzers, no misbehaving peers, no scenario that reproduces a defect that is not
already public. A scenario names the public issue or pull request it reproduces. If you find a node defect
while using peeryard, `SECURITY.md` says where it goes; not here.

**Before a pull request**
- `shellcheck -x` on every script you touched (the repository's `.shellcheckrc` lists the deliberate
  exceptions), and `bash -n`.
- The no-node self-tests: `T=$(mktemp -d) bash tests/sequential.sh`, `... tests/lint.sh`, `... tests/precheck.sh`, `... tests/tooling.sh`;
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

**Adding a rig example.** A topology file and a hook that sets `rig_verdict=PASS` or `FAIL`, listed in
`rig/README.md`'s table with one line on what it checks.

**Style.** Plain bash (4.4 or later), `jq`, POSIX tools; no new runtime dependencies without a reason in the PR. Say what a
number means and where it came from. Prefer a failing check to a silent fallback.
