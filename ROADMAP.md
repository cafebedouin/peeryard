# peeryard roadmap

What peeryard covers today, what is planned next, and what is out of scope. Contributions to any item are welcome
(`CONTRIBUTING.md`); an item moves to "done" when it ships with a witnessed run.

peeryard tests honest nodes under benign network conditions: delay, loss, partitions, crashes, damaged data
directories, mixed versions and implementations. It does not ship attack tooling (crafted messages, lying or
withholding peers, eclipse set-ups, fuzzers), and none is planned.

## Coverage today, by layer

| layer | covered | examples |
|---|---|---|
| peers | isolation by magic, connectivity, peer sets against the topology, churn (late join, crash, rejoin) | `magic`, `churn`, `netsplit` |
| chain sync | fork choice under delay and partition, digest and pruned followers, UTXO-snapshot and NiPoPoW bootstrap | `fork-convergence`, `sibling-fork`, `bootstrap-modes`, `utxo-bootstrap`, `nipopow-bootstrap` |
| block production | mining control, retarget, orphans under latency, sub-blocks on the Matrix line | `mining`, `soak`, `matrix-pair`, `matrix-mixed` |
| transactions | payments, chained spends, mempool capacity and eviction, re-admission after a reorg | `txload`, `txchain`, `mempool-evict`, `reorg-mempool` |
| state | state-root agreement at a height, recovery from damaged data directories | `same_state` in most examples, `corruption` |
| implementations | the Scala node with two Rust implementations on one network | `arkadianet-*`, `ergo-node-rust-*` |
| pull requests | before/after verdicts with A/A calibration, a review workflow, the fixes peeryard carries | `diffrun/`, `review/`, `patches/` |
| hosted runs | the example suite and one pair per scenario on GitHub-hosted runners (`.github/workflows/sweep.yml`, 2026-09-26: 29 of 33 jobs green, the rest in `rig/examples/experimental.txt` or fixed), the A/A calibration (`aa.yml`) | `.github/workflows/` |
| cost | what recovery costs, not only whether it happens: per-node CPU pinning and JVM options in the topology, an event log and per-node REST time, CPU, memory and disk I/O on one clock, and per heal and revive the time to agree again (`diag/costs.py`, `costs.json`); a flapping link | `loss`, `flap`, `three-body-*`, `revive-headroom` |
| diagnosis | a named cause for every INCONCLUSIVE or FAIL (node down, stalled, lighter fork not switching, setup step), in the verdict and the run log | `diag/diagnose.py`, `cause` in `verdict.json`; `diag/features.py` ranks per-run features from the kept node logs against the runs' outcomes; `diag/sweep.py` finds what is new in a batch of runs against earlier runs (novelty) or unusual within it; `diag/logmap.py` names the source line behind each log message (both tools take `--source`) |

## Next

First, the conditions upstream already cares about, reproduced here and turned into node-level tests:

- **Upstream's flaky multi-node specs**: `DeepRollBackSpec` timeouts and the `UtxoStateNodesSyncSpec` stall
  (#2452), each with a scenario and a deterministic test for the cause.
- **Delivery expirations under latency** (#2528).

Then the tooling that serves them:

- **Declarative scenario phases**: prefix, partition, freeze, heal and observe as data instead of bash hooks.
- **Topology as a manifest parameter**, so a sweep over shapes (line, star, mesh, clusters) is data.
- **Futility stopping**: end a sequential run once the verdict can no longer change.
- **One timeline collector**: `/info`, peers and mempool per node on one clock, for every run. The first slice has
  shipped (`/info`, REST time, CPU, memory, disk I/O and the rig's events, `rig/README.md` *Events, samples, costs
  and the wire*); peers and mempool are not on the clock yet. With the wire on, the P2P messages are on the same clock
  (`diag/README.md`, *Wire observer*).
- **Cross-implementation message diff**: the same scenario with a JVM, an ergo-node-rust and an arkadianet peer,
  their `messages.jsonl` compared message by message (what each sends, in what order, how much), in the style of the
  SANTA conformance vectors.
- **Canary message-pattern alerts**: the scheduled runs keep a per-scenario profile of their messages (counts per
  kind, sync cadence, bytes per recovery) and alert when a new release drifts from it.
- **Bytes and messages per recovery** in `costs.json`: per heal and revive, what crossed the link until agreement
  (a lower bound where the capture had a gap).
- **Costs under diffrun**: compare `costs.json` (`agree_s`, `loopback_info_ms` p95) between two jars, as diffrun
  compares verdicts.
- **Hard CPU quotas and disk throttling per node** (cgroup `cpu.max`, `io.max`) on hosted runners, which have root. On
  a host where the cgroup controllers are not writable by the user, the knobs refuse to run rather than run unthrottled.
- **A node behind NAT**: it can dial out but cannot be dialled (connection filtering in its namespace), then healed.
  One-way loss at 100 % is not this case: TCP needs both directions, so it is a partition.
- **netem as first-class fields**: bursty loss (`loss gemodel`), `reorder` and `duplicate` (bandwidth has `rate_kbit`).
- **JVM and collector variants under low CPU** through `java_opts` (Serial, Parallel, ZGC; JDK 17 and 21).
- **Background load** (`load_start <workers>`): busy loops, which model CPU contention and nothing else.
- **Trace replay**: a recorded latency and loss trace (timestamp, rtt_ms, lost) replayed through netem.
- **Randomized flapping**, seeded.
- **CPU headroom and fork choice on a larger runner class**, if the single-host comparison shows an effect.
- **Activation on a mixed network**: a soft-fork vote and activation with old and new nodes side by side.
- **Download-stall measurement across implementations**: how long a follower waits for block sections from a
  peer of another implementation.
- **Reorg variants**: independent and chained payments in the reorg example.
- **NiPoPoW bootstrap with a pruned digest node.**
- **Clock skew per node** (libfaketime).
- **A designed failing control for every rig example** (`rig/README.md`, *Seen to fail*): the examples not yet seen to
  fail get a control that must FAIL, as `magic` and `netsplit` have.

## Scenario backlog (conditions not yet tested anywhere public)

- Soft partitions: fork resolution when links are slow rather than cut.
- Reorder and duplication at 1-5% on live links (loss has the `loss` example).
- Round-trip time near the block interval: sync-status classification under jitter.
- Connect and handshake timeouts against high-latency peers.
- Reorgs under load: repeated shallow reorgs with UTXO, mempool, wallet and indexer compared across nodes.
- Propagation depth on a line topology with per-hop latency.
- Mixed node roles (pruned, digest, snapshot-bootstrapped) under latency and partition.
- Deep forks on young chains: forks deeper than the sync summaries reach (more than 16 blocks below 128, more than
  128 below 512), as on fresh test networks and CI.

## For contributors with other hardware

peeryard is developed on one small x86 machine and tested on GitHub-hosted runners (4 CPUs and 16 GB for a public
repository), and a rate measured on one host is a fact about that host. Results from other machines are wanted. Run
each example at least three times, and open an issue with the run directories' `effective.json` (it carries a host
card), the verdicts, and `costs.json` where there is one (`.github/ISSUE_TEMPLATE/contributor-run.md` lists them).
Label disk- and hardware-dependent results as characterizations: drive caches and thermal limits are not controlled
variables.

| you have | run | what it tells us |
|---|---|---|
| any Linux host unlike ours (bare metal, other clouds, more cores) | the A/A calibration for `fork-convergence` and `sibling-fork` (`diffrun/README.md`) | whether the release's base rates hold across host classes; the verdict rule has to hold across that range |
| arm64 (Graviton or Ampere, Raspberry Pi 5 with 8 GB, Apple Silicon under a Linux VM) | the example suite and one A/A | the first non-x86 results |
| a hybrid-core CPU on bare metal (Intel 12th generation or later) | `three-body-*` with nodes pinned to performance or efficiency cores (`cpus`; `lscpu --extended` shows which is which) | whether core class, not only core count, changes catch-up and fork choice; a VM without vCPU pinning will not do, because its virtual CPUs move between core types |
| 32 GB of RAM or more | topologies of 8 to 16 nodes (`rig/topo.sh` generates line, star, mesh and clusters) | propagation depth and peer behavior beyond what a small host holds |
| different disks and filesystems (NVMe with and without DRAM cache, SATA, HDD, SD card, USB; ext4, xfs, btrfs, ZFS) | `soak`, `corruption` and the bootstrap examples with `SCRATCH` on each | restart and catch-up cost per disk class |
| root on a spare Linux box or VM host | crash consistency: hard VM resets, or the device-mapper `log-writes` target and its `replay-log` tool, replaying writes to each flush point (not built; design help welcome) | recovery from what SIGKILL cannot model (lost page cache, torn writes) |
| an unusual network (Wi-Fi, LTE or 5G, satellite, a distant region) | nothing but a timestamped ping log (`ping -D -i 0.2 <host>` for an hour) | measured, bursty conditions for trace replay (planned) instead of independent random loss |
| two or more machines | a multi-host run (not built; design help welcome) | whether netem-shaped runs predict real links |
| a synced mainnet node, 32 to 64 GB of RAM and a fast disk | copy its data directory into several namespaces with no route out, then measure resync and UTXO-snapshot and NiPoPoW bootstrap at mainnet size under shaping. The rig starts devnet nodes today, so this needs a mainnet-data mode (not built; design help welcome); `rig/examples/nipopow-bootstrap.json` shows the settings both bootstrap halves need on a devnet | sync cost at real size. The copied chain can be synced from but, in practice, not extended (a sealed network lacks the hashrate to mine at mainnet difficulty), so this measures sync, not fork choice. These nodes use mainnet's network magic, so isolation rests on the namespaces having no route out: check that first |
| an indexed node (`extraIndex`) | `du` of its data directory, with node version and height | a current size figure, which we do not have |
| an always-on machine | soaks of days to weeks | memory, compaction and disk growth that only show over days |
| a Linux GPU miner | a client that can solo-mine against the node's mining API (many only talk to pools), pointed at a devnet node | difficulty retargeting after a real hashrate step, candidate refresh and orphans at real hashrate |
| small hardware (Raspberry Pi 4 or 5, a 1 to 2 vCPU VPS) | followers (full, digest, pruned) under shaping | whether the machines many home operators use keep up; on one CPU the JVM picks SerialGC, which is part of what this measures |
| a different JVM (GraalVM, OpenJ9, JDK 17 or 21), or an interest in collectors | the examples with `PEERYARD_JAVA` or `java_opts` choosing the JVM or collector (Serial, Parallel, ZGC) at low CPU | whether the JVM, rather than the node, sets the cost of recovery when headroom is small |

## How findings are delivered

A behavior found on a peeryard network is handed over with a node-level test that forces the same state without
timing (the node's own test fixtures), so a maintainer can run it in seconds, and with the scenario that found it.

## Beyond the node

- **The review queue page**: a daily, rules-as-data view of which open pull requests need a review and which need
  a maintainer, with rules anyone can change by pull request.
- **Application-layer protocols on the network**: running a protocol built on Ergo (its off-chain actors and
  contracts) on a peeryard network, to test its liveness and safety assumptions under the same conditions.

## Out of scope

- Attack tooling of any kind (see the top of this file).
- Mainnet-scale load from one small host: peeryard is bounded by one machine's memory (about 350 MB per JVM node on a
  devnet chain). Mainnet-sized data on a bigger machine is a contributor item above.
- Deterministic simulation (Jepsen or TLA+ style): a different tool.
