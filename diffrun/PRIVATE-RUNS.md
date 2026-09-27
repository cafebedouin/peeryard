# Private runs: tiers and the optional lint

Moved out of the runner's README: nothing here is needed to run the public scenarios.

## Tiers and lint

- `tier: public` covers behavior that is already public. `tier: private` covers anything else;
  `run.sh` refuses a private manifest when `CI` or `GITHUB_ACTIONS` is set.
- For a public manifest, `run.sh` lints the manifest and its script before launching, and lints its own
  `verdict.json` and `table.txt` before writing them; a hit refuses (exit 5) and **withholds those two files
  only**: the per-run `stdout.txt`, `result.json`, `runs.jsonl` and `run_meta.json` are already on disk under
  `--out` and are not scrubbed, so treat that directory as private until you have looked at it. A term list
  that `grep` cannot parse makes the lint fail closed (exit 2) rather than pass.
- The term list is optional and yours (`DIFFRUN_TERMS`, one extended regex per line); without it the lint is
  skipped. Use it when a scenario concerns something not yet public. **The lint is a known-term backstop, not
  proof that content is safe to share.**

