# audits: the evidence of a run, kept next to what it produced

One directory per run, `audits/<date>_<slug>/` (for a pull-request review `<date>_pr-<N>`). Git ignores
everything here except this file and the example, so the evidence stays on the machine that made it and can
answer follow-up questions later. The layout follows the one this tool was built with:

```
audits/2026-09-23_pr-2511/
  PREREGISTRATION.md      written BEFORE the first run: what is tested, what would count against it
  captures/               every command's output as it ran (one file or one --out directory per run)
  REPORT.md               the report as written from the captures (and, for a review, the text posted)
  reviews/                the three review reports on the draft (derivation, fidelity, maintainer)
  send/                   what was actually posted, with the URL and the time
```

`PREREGISTRATION.md` has three required fields, first: the claim tested (what this run would show about the
pull request), what counts against it (the results that would refute the claim; if none could, the run is not
a test), and what a careful reviewer without this tool would find by ordinary means. Then the method: numbered
steps, each naming the capture it produces. It is committed (or at least saved) before the first capture; the
report quotes it and never edits it; corrections go under `## Amendments` with their own timestamp.

`EXAMPLE_pr-review/` is a filled-in skeleton.
