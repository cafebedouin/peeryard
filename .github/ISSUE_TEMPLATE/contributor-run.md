---
name: Contributor run (other hardware)
about: Results from a machine unlike the development host (ROADMAP.md, "For contributors with other hardware")
title: "run: <example or scenario> on <machine>"
labels: contributor-run
---

**Machine.** One line in your own words (e.g. "Raspberry Pi 5, 8 GB, NVMe over PCIe, Debian 12"). The host card in
`effective.json` records the rest: attach it rather than retyping it.

**What you ran.** The example or diffrun scenario, the command line, and any environment you set (`PEERYARD_*`,
`SCRATCH` and the filesystem it was on, `cpus` or `java_opts` in the topology).

**Node build.** The jar or binary and its sha256 (`effective.json` has the first 16 hex digits per node).

**Results, at least three runs.** For each run:
- the verdict line (`...: PASS` / `FAIL` / `INCONCLUSIVE`) and, for a FAIL or INCONCLUSIVE, the `[rig] CAUSE` line
- `out/effective.json`
- `out/costs.json` where the run has one (the `[rig] COSTS` line is its summary)

Attach the files (a zip of the `out/` directories is fine; node logs help with a FAIL). Disk- and hardware-dependent
numbers are characterizations of your machine, not controlled measurements: say what else was running.

**Anything surprising.** Optional.
