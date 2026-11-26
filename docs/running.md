# Running peeryard: host setup, run card, outputs, self-tests

The top `README.md` has the first run and the quick start. This page has what they leave out: what the host setup
changes, everything a run needs, where a run writes, and the tests that need no node.

## Host setup, once

Installing the packages and two commands need `sudo`; nothing else in peeryard does.
```
sudo apt-get install -y jq iproute2 util-linux procps coreutils curl unzip git python3 default-jre-headless   # Debian/Ubuntu names
sudo apt-get install -y openjdk-8-jdk   # only to build candidate jars; sbt too: https://www.scala-sbt.org/download
sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0   # Ubuntu 23.10+ only; see below
sudo modprobe sch_netem
unshare -Urmn true && echo "user namespaces ok"
bash rig/preflight.sh
```

**The AppArmor sysctl.** It exists only on Ubuntu kernels (23.10 and later). It turns off, for **every program on the
host**, the AppArmor rule that stops unprivileged programs from creating user namespaces; that rule is a hardening
measure that narrows the kernel code a local unprivileged process can reach. Setting it to 0 gives that hardening up
until the next reboot, when the value resets to 1 (it is not written to `/etc/sysctl.d`). On other distributions the
key does not exist and unprivileged user namespaces are usually allowed already: if `unshare -Urmn true` succeeds,
skip the sysctl. A host you would rather not change can use the container below instead.

## Run card

You need:
- Linux with unprivileged user namespaces, `iproute2` with `sch_netem`, util-linux (`unshare`, `nsenter`), procps
  (`ps`, `pgrep`, `pkill`), coreutils (`timeout`, `sha256sum`, `realpath`), `jq`, `curl`, `unzip`, `git`, `python3`
  (the rig's cause classifier and the diag tools; standard library only), **bash 4.4 or later**, and a Java runtime
  for the node (the example runs used OpenJDK 21);
- **JDK 8 and sbt**, only to build candidate jars (`diffrun/build.sh --dry-run` needs neither); set `JAVA8_HOME` if
  JDK 8 is not under `/usr/lib/jvm`;
- for the Matrix examples, the `weak-blocks` reference node (`patches/sigma-snapshot.sh` once, then
  `patches/stack.sh --build ergo-matrix`; `patches/README.md`), and for the Rust examples an arkadianet or
  ergo-node-rust binary (`rig/README.md`); `rig/run-suite.sh` skips what is not set;
- about 1.5 GB of free RAM for a four-node scenario (`rig/README.md`: about 350 MB per node at `-Xmx512m`).

`rig/preflight.sh` checks the first item (namespaces, netem, every command named there, the Java runtime) and the
free memory, and fails closed on any miss; JDK 8, sbt, `taskset` (a topology node with `cpus`) and `tar` (fixture
snapshots) it reports without failing; it does not look for the Matrix or Rust node binaries.

**Docker is optional, two ways.**
- `bash docker/run.sh` builds an image with the whole run card and starts a shell in it at `/peeryard`, with the flags
  the rig needs already set (`docker/Dockerfile` explains each; by hand they are `--init --security-opt
  seccomp=unconfined --security-opt apparmor=unconfined --security-opt systempaths=unconfined`, no `--privileged`, no
  root inside). The clone, your `PEERYARD_JAR` and `DIFFRUN_ERGO_CLONE` are mounted, and the container's home is a host
  directory so caches survive restarts (`docker/run.sh --help`). This is the route for macOS and for hosts where
  unprivileged user namespaces are locked; the first command inside is `bash rig/preflight.sh`, which checks the
  container the same way it checks a host.
- `review/it-spec.sh` runs one of ergo's own Docker integration specs on a PR's tree, the suite upstream's CI runs,
  which peeryard treats as a dependency it calls, not code it carries.

## How long things take

A fork-convergence run takes 3–7 minutes; a full verdict takes 8–12 paired runs, 1.5 to 2.5 hours. The first sbt build
on a host downloads its dependencies (10 to 20 minutes); later builds of the same inputs are served from the cache. The
timings in these docs come from a development host from 2019 and GitHub-hosted runners (2 and 4 vCPUs); a newer
machine is faster.

## Exit status of a rig run

0 PASS, 1 FAIL, 3 INCONCLUSIVE. INCONCLUSIVE is not a verdict on the node: the run could not show what the example
checks, and a `[rig] CAUSE` line says why (`HARNESS` means a rig step, such as a partition, a crash or a restart, did
not happen as asked). Exit 2 or 10 means the rig could not bring the network up (a node never answered, a link never
connected, a namespace or netem step failed) before the example started; the last `[rig]` lines say which.

## What gets written, and where

- the rig: its scratch directory (`SCRATCH`, default a fresh `mktemp -d` under `$TMPDIR` or `/tmp`, which is not
  deleted afterwards), and node logs under a topology's `log_dir` when it sets one (anywhere it names);
- `rig/devnet.sh`: `~/.peeryard/devnet/<name>` (or `PEERYARD_DEVNET_DIR`);
- `rig/node-release.sh fetch`: release jars under `~/.peeryard/jars/`, with their sha256 in `SHA256SUMS`;
- `diffrun/run.sh`: its `--out` directory (default a fresh `diffrun.<scenario>.*` directory under `$TMPDIR` or `/tmp`);
- `diffrun/build.sh`: the jar cache (`DIFFRUN_CACHE`, default `~/.cache/diffrun/builds`), with the temporary build
  worktree inside it (`$DIFFRUN_CACHE/.tmp.*/wt`; git's bookkeeping for it goes in the ergo clone's `.git`), and a short
  socket directory under `/tmp` that sbt needs; sbt and coursier keep their own caches under `$HOME` (`~/.sbt`,
  `~/.ivy2`, `~/.cache/coursier`);
- `review/revert-check.sh`: `/tmp/revert-check.*` unless `--out` is given;
- a review: `audits/<date>_pr-<N>/` (ignored by git except the layout and an example; `audits/README.md`).

## Self-tests (no node, seconds)

The same set `.github/workflows/checks.yml` runs on every push, from the peeryard root:
```
python3 -m unittest discover -s tests -p '*_test.py'     # diagnose, features, sweep, logmap, aa_pool, queue, wire, matrix, ...
bash tests/leakcheck.sh                                   # no register files or ids travel with peeryard
for t in lint precheck sequential phases indexer_diff crash_consistency wallet_oracle wallet_workload pr_path rig_checks tooling; do
  T=$(mktemp -d) bash "tests/$t.sh" || echo "FAILED: $t"
done
```
`T` must be a fresh empty directory: each test deletes it first. `tests/tooling.sh` makes commits, so it needs a git
identity (`checks.yml` sets one). `tests/diffrun_pool.sh` (the sharded-verdict pooler) runs the same way but is not
in `checks.yml`. Each shell test exits non-zero on a `MISMATCH`. `checks.yml` also runs `shellcheck -x` and `bash -n`
over every bash script and `ci/export-workflows.sh --check`.

## Test values in the tree

The mnemonics, the REST API key `hello` (and its hash) and the solver key in `rig/rig.sh` and the example topologies
are public devnet test values, not secrets: they unlock only the private devnets peeryard starts.
