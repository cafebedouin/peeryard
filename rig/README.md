# rig: N Ergo nodes on one host, with per-link network conditions

`rig.sh` starts N real Ergo nodes (the JVM reference node, from a jar you provide) on one Linux host. Each node
runs in its own network namespace, and every link is a veth pair with per-direction `netem`. It then sources a
hook script that drives the experiment. No root, no Docker.

```
PEERYARD_JAR=~/ergo-6.0.6.jar bash rig/rig.sh rig/examples/bringup.json rig/examples/bringup.sh
```

## Requirements
- Linux with unprivileged user namespaces (`unshare -Urmn` must work; on Ubuntu 23.10+ see the sysctl in the top
  README), util-linux (`unshare`, `nsenter`), procps (`ps`, `pgrep`, `pkill`), iproute2 (`ip`, `tc`) with the
  `sch_netem` kernel module (`sudo modprobe sch_netem` once if it is not loaded), `jq`, `curl`, `unzip`, bash 4.4+
- a Java runtime the node jar supports, and about 350 MB of RAM per node (`-Xmx512m` each)

It writes under its scratch directory (`SCRATCH`, default a fresh `mktemp -d` under `$TMPDIR` or `/tmp`; it is not
deleted afterwards, so full node data accumulates there until you remove it) and, when a topology sets `log_dir`,
node logs there. Every node is stopped when the script exits. If it is killed hard, `pkill -f <scratch>/conf_`
stops the nodes; give each concurrent rig its own `SCRATCH`, since that pattern matches by path.

## Topology schema
```json
{
  "jar": "/path/to/ergo.jar",
  "magic": [112, 101, 101, 114],
  "chain": "current",
  "log_dir": "/path/for/node/logs",
  "runtime_cwd": "/dir/with/src/main/resources/*.conf",
  "nodes": [
    { "name": "A", "mining": true, "mine_poll": "500ms", "knownPeers": [], "p2p": 9021, "rest": 9052,
      "conf": { "scorex.network.maxConnections": 10 }, "defer": false },
    { "name": "B", "knownPeers": ["A"], "jar": "${PEERYARD_JAR_B}" },
    { "name": "C", "knownPeers": ["A"], "kind": "arkadianet", "bin": "${PEERYARD_ARKADIANET_BIN}" }
  ],
  "links": [ { "a": "A", "b": "B", "delay_ms": 0, "loss_pct": 0 } ]
}
```
Only `nodes[].name` and `links[].a/b` are required. Other fields:
- `jar`: the jar every node runs unless it names its own; or set `PEERYARD_JAR`.
- `nodes[].jar`: this node's jar, for **mixed versions** on one network (a release next to a candidate build, or
  old nodes around a node with a new feature). `${VAR}` in any jar path is expanded from the environment, so an
  example topology can stay free of local paths. Each node gets a working directory with its own jar's `*.conf`.
- `nodes[].kind`: the implementation, `jvm` (default), `arkadianet` or `ergo-node-rust`, with `nodes[].bin` the node
  binary (or `PEERYARD_ARKADIANET_BIN` / `PEERYARD_ERGO_NODE_RUST_BIN`). A topology with a non-jvm node must use
  the chain preset `rust-devnet`. See *Other implementations* below.
- `magic`: the network magic. The default `[112,101,101,114]` ("peer") is private, so these nodes never talk to a public network.
- `chain`: the parameters every node must share, as a preset name or an object. Presets:
  The JVM devnet presets start at block version 3 (the 5.0 rules; `DevnetLaunchParameters`), so no shipped example
  exercises a 6.0-only rule; `rust-devnet` (networkType `devnet60`) has its own launch parameters.
  - `current` (default): `blockInterval = 2s`, a fixed difficulty target at a sub-block pace, deliberately not
    tied to any miner's polling rate, so retargeting (every 16 blocks: the devnet's `epochLength = 16`) settles within the first epochs instead
    of drifting; and `minerRewardDelay = 10`, so mining rewards are spendable within a run (devnet's own default
    is 720 blocks).
  - `matrix`: for nodes with sub-blocks (input blocks between ordering blocks). The jar's own block interval is
    left alone, because a 2 s ordering-block target would collide with the sub-block cadence; only the reward
    delay is shortened to 10. Use it for a network of Matrix-line nodes, or set `"chain": "devnet"` and shape
    nothing. The devnet starts at block version 3 and only votes for version 4 (activation around height 2,000), and
    on the Matrix line the version decides how transactions are placed (from version 4 they go into input blocks).
    `"v4": true` in the chain object, or `PEERYARD_V4=1`, shortens the soft-fork vote (voting length 4, one
    soft-fork epoch, one activation epoch) so version 4 activates at about height 16, with the preset's difficulty
    and interval kept, so input blocks still form. `rust-devnet` is version 4 from genesis but at difficulty 1,
    where no input block can form, so it does not serve for this. `effective.json` records `chain.v4_early`.
  - `devnet`: nothing overridden.
  - `rust-devnet`: the private devnet compiled into the Rust implementations (arkadianet's `network = "devnet"`;
    ergo-node-rust's devnet network): magic `[7,7,7,7]`, protocol version 4 from genesis (the JVM node runs as
    `networkType = "devnet60"` with the same overrides, launched without `--devnet`), difficulty 1 with an
    unreachable epoch boundary, a 20 s block interval, the testnet genesis boxes, a 720-block reward delay and no
    re-emission. Every JVM node is configured to those values so the implementations agree on the chain; the
    preset takes no chain overrides. Its magic defaults to `[7,7,7,7]`; a topology may set another magic only
    with Rust binaries that accept a devnet magic override (arkadianet `[chain] devnet_magic`, ergo-node-rust
    `[proxy] magic`, both proposed upstream), which the rig then writes into their configs. The JVM internal miner
    finds a block on every poll at difficulty 1, so a miner's `mine_poll` sets the block rate. Wallet payments
    need 720 blocks of maturity here.
  An object (`{"preset": "current", "blockInterval": "3s", "minerRewardDelay": 20, "genesisStateDigestHex": "…"}`)
  overrides fields of a preset. The reward delay is part of the emission contract, so it changes the genesis
  state digest the node asserts on at startup; with a delay override and no digest given, the rig starts one
  probe node, reads the digest the node prints before refusing, and uses it (about ten seconds). Of the shipped
  scenarios under `diffrun/`, `fork-convergence` and `sibling-fork` are standalone scripts and keep devnet's
  defaults; `interop`, `txload` and `bootstrap-modes` run on the rig and use its presets.
- `runtime_cwd`: the default is each node's own jar's `*.conf` files, unpacked into the scratch directory.
- `conf`: extra HOCON lines for one node, as dotted keys.
- `defer`: when true, the node is not started at bring-up; the hook calls `launch <n>; wait_up <n>`, for example
  after setting `CONF_OVR[n]="ergo.chain.genesisId=…"`.
- `cpus`: the CPUs this node runs on, in `taskset` list syntax (`"2-3"`, `"0,4"`); every launch of the node (first,
  relaunch, revive) is wrapped in `taskset -c`. The JVM sizes its GC and compiler threads from that mask (JDK 21 under
  `taskset -c 0,1`: `ParallelGCThreads` 2), so one field gives both the real limit and the JVM's view of it; it also
  changes the collector the JVM picks (JDK 21 with `-Xmx512m`: SerialGC under a one-CPU mask, G1 under two), so the
  collector is part of the condition. A list outside the rig's own mask (a `taskset` around `rig.sh` narrows it) refuses
  the run with `cpus outside rig affinity: node=<n> requested=<list> allowed=<mask>` (exit 2); it is never silently
  unpinned. Each launch records what the kernel applied (see *Events* below). `set_cpus <node> <list>` changes it for
  the node's next launch, e.g. before a revive. On a machine whose virtual CPUs are hyperthread pairs (WSL2 reports
  0-1, 2-3, ... as siblings), two CPUs may be one physical core: "strong" is then nominal.
- `java_opts`: extra JVM options for this node (`jvm` nodes only; any other kind that sets it is refused), appended
  after `PEERYARD_JAVA_OPTS`, e.g. a smaller heap, another collector, or `-XX:ActiveProcessorCount=<n>` (the JVM's view
  of the CPU count without a real limit).

Each link gets its own `/30`, so a node on several links has one IP per link, and `knownPeers` dials each peer on
the link the two nodes share. The node settings follow the node's own integration-test devnet template
(`src/it/resources/devnetTemplate.conf`), with these deliberate differences: `mining` and `offlineGeneration` are
set per node (the template sets both true for every node; a rig follower does not mine); the default
`mine_poll` is `500ms` where the template's comment names `1s` as the safe floor when several nodes mine at
once (set `mine_poll` per miner when a topology has more than one; the shipped scenarios do); and the `chain`
defaults above (a 2 s block-interval target, a 10-block reward delay) replace devnet's 100 ms and 720.

## Hook helpers
Call forms, printed tokens and side effects: [HOOK_API.md](HOOK_API.md).
Listed at the top of `rig.sh`. The main ones:
- observe: `rest`, `full_height`, `header_at`, `same_chain`, `applied_header`
- oracles: `same_state <a> <b>` compares UTXO state roots at equal full heights (`SAME@h`, `DIFF@h`, `NOHEIGHT`
  when either node has no full block yet, or, while the heights differ, `LAG@ha,hb same-chain` / `LAG@ha,hb fork` / `LAG@ha,hb unknown`: the lower node's best
  full block against the higher node's header at that height), a stronger consensus check than header ids;
  `settle_follow <leader> <follower> <min_h> [window_s]`, called while the leader mines, drops the leader to a slow
  poll (`SETTLE_POLL`, 20 s), waits for `SAME@h` at `h >= min_h` between blocks, then pauses the leader; pausing
  first (a relaunch) can leave a 6.0.5 follower behind indefinitely (block sections cached before their header
  are not applied until more sections arrive; addressed by ergoplatform/ergo#2549 in 6.0.6), and the trickle of
  blocks drains that cache; it sets `SETTLE_STATE`, `SETTLE_TRICKLE`, `SETTLE_WAIT_S`, `SETTLE_AFTER` (the
  interop scenario reports the trickle as `trickle_ab` / `trickle_ba`); `peers_of <node>` and
  `check_topology` (every unpartitioned link connected both ways, no connection without a link; a node with
  `knownPeers: []` is inbound-only and is still expected to be connected, dialled by its neighbours);
  `orphans_between <node> <h0> <h1>` counts header ids beyond the first per height (siblings later abandoned);
  `rss_mb <node>` and `data_mb <node>` for resource records
- shape a link: `link_netem <a> <b> <spec>` (one direction), `partition <a> <b>` / `heal <a> <b>` (both
  directions — a 100%-loss cut that keeps the TCP sockets, then restore the link's configured shaping)
- node lifecycle: `relaunch` (graceful stop+start, chain kept), `crash <node>` (SIGKILL, left down) /
  `revive <node>` (bring back, chain restored from disk), `launch`/`wait_up` for a deferred node; on a stopped
  node, `corrupt <node> <injury>` (honest damage to its data directory) and `wipe <node>` (delete it)
- mining: `mine <node> <n>`, `stop_mining` / `start_mining`; `solve_start <node>` / `solve_stop <node>` drive a
  node that only serves candidates (see *Other implementations*). With `PEERYARD_EXTMINE_POLL=<1s|4s|...>` every JVM
  node that mines runs without its internal CPU miner (`useExternalMiner = true`) and is mined by `lib/extminer.py`,
  which reads `GET /mining/candidate` at that interval, as a pool or mining proxy does, searches Autolykos v2 nonces
  on the last candidate it read (the node verifier's hit; `PEERYARD_EXTMINE_RATE` caps nonces per second, default
  0 = one core) and posts a hit below the target `b` to `/mining/solution`; on a Matrix node (`/info` parameters carry
  `subblocksPerBlock` = k) a hit below `b * k` goes to `/mining/weakSolution` as an input block. After a submission
  it reads the candidate again at once. The first block of a fresh chain is an Autolykos v1 header (block version
  1), which only the node's own key solves: a miner on an empty data dir mines it with its internal miner, then the
  rig relaunches it with the external miner before the hook runs. On the weak-blocks line at 8769baace no external
  solution reaches the candidate generator (ErgoMiner forwards only a bare `AutolykosSolution`, the routes send
  `OrderingSolutionFound` / `InputSolutionFound`; each request times out after 5 s), so Matrix nodes mine nothing
  this way until that is fixed; release jars accept external solutions. Log per node: `out/extminer_<node>.log` (candidates
  read, each submission and the node's reply, a summary on stop)
- payment load (`lib/txload.sh`): `txload_fund <from> <nanoerg> <to>...`, `txload_start <per 10 s> <node>...` /
  `txload_stop` (honest wallets paying each other at random; `TXLOAD_CHAIN_PCT` (30) of ticks send
  `TXLOAD_CHAIN_LEN` (3) payments back to back from one wallet, so later ones may spend unconfirmed change),
  `txwatch_start <node>...` / `txwatch_stop` (each node's best full block and, on the Matrix line, every input block
  new in its best input chain with its transaction ids), `txload_pools <node>...`, `txload_chain <node> <h0>`;
  `diag/txload_report.py <out>` joins them into one record per payment (`txrecords.jsonl`: submit time, node, id,
  dependent, first input block seen, holding ordering block, confirmed / pending / lost). `matrix-compat` runs it
  with `MATRIX_COMPAT_TXLOAD=<per 10 s>`
- wallet and transactions: `address <node>`, `balance <node>`, `pay <from> <to> <nanoerg>` (a real payment from
  a miner's rewards; prints the tx id or the node's rejection text), `pay_from <from> <to> <nanoerg> <box id> [fee]` (the same, spending exactly that confirmed box),
  `send_fee <from> <to> <nanoerg> <fee>` (the
  same with an explicit fee), `wait_balance <node> <min> [s]`, `block_txs <node> <height>`; `txchain <from> <n>`
  (a burst of self-payments forming a dependency chain in the mempool), `mint_boxes <node> <txs> <outputs>` (grow
  the UTXO set, batches left to confirm), `mempool_ids <node>` / `mempool_size <node>` (the unconfirmed pool as
  the node lists it). Every node's wallet is initialized and unlocked from its test mnemonic; give a
  node its own keys with a `conf` override of `ergo.wallet.testMnemonic` (see `examples/txload.json`).
- verdict: a hook sets `rig_verdict=PASS`, `FAIL` or `INCONCLUSIVE` (the check could not be exercised, e.g.
  `corruption`, `mempool-evict`); `rig.sh` exits 1 on FAIL, 3 on INCONCLUSIVE and 0 otherwise, so a caller can
  chain on it.
- named cause: while the hook runs, every node's `/info` is sampled every `PEERYARD_SAMPLE_S` (default 3) s into
  `samples.jsonl` beside the node logs. After a FAIL or INCONCLUSIVE the rig prints `[rig] CAUSE <NAME>: evidence`
  (also `cause.json`) from `diag/diagnose.py`: `NODE_DOWN`, `NODE_UNRESPONSIVE`, `NO_PEERS`, `BEST_CHAIN_INCONSISTENT`
  (#525), `HEADERS_AHEAD_FULL_STUCK`, `NODE_LAGGING`, `EQUAL_HEIGHT_TIE`, `LIGHTER_FORK_NOT_SWITCHING`,
  `CHAIN_STALLED`, `STILL_PROGRESSING` or `UNKNOWN`. A node that ends the run cut on every one of its links (its last
  `partition`/`heal` event on each link is a `partition`) makes the cause `PARTITIONED`, which names the node; the
  samples-based cause is kept in `cause.json` as `observed`. With the wire on, a `LIGHTER_FORK_NOT_SWITCHING` carries
  a wire stage (`diag/README.md`, *Wire observer*). A hook that knows its own reason sets `rig_cause=<CODE>`
  (printed first, e.g. `STAGING_OVERSHOOT`). `python3 diag/diagnose.py <samples.jsonl>` re-reads any kept run.
- a link that comes and goes: `flap <a> <b> <down_s> <up_s> <cycles>` runs `partition`, waits `down_s`, `heal`s, waits
  `up_s`, `cycles` times, in the hook's own shell (it returns after the last up period; edges are scheduled from its
  start, so they do not drift); its partition and heal events carry `flap i/N`, and it sets `FLAP_LAST_HEIGHT` (the
  first node's full height at the last edge)
- phases: `mark <label>` writes a labelled event (below)

A hook can also be written as data: one phase per line (`floor`, `wait`, `pass`, `record`, actions such as `partition`
or `settle_follow`), checked before anything runs and interpreted by `lib/phases.sh`. It is an optional runner for
hooks that are generic phases plus a pass rule; the grammar and the verdict rules are in [PHASES.md](PHASES.md).

### Events, samples, costs and the wire
Beside the node logs, every run keeps three records on one clock (epoch milliseconds), and a fourth when asked:
- `events.jsonl`: one line per `partition`, `heal`, `link_netem` (detail: the tc spec), `crash`, `revive`, `relaunch`,
  `launch` and `mark`, as `{t, kind, a, b, node, detail}`. A `launch` event also carries the node's `pid`,
  `cpus_requested`, `cpus_applied` (its `Cpus_allowed_list` after the exec chain reached the node binary: what was
  applied, not what was asked), `gc` (the collector a `-XX:+PrintFlagsFinal` probe selects under the same mask and
  options) and `java_opts`. Once the hook runs, each event is followed by one sample taken at that moment.
- `samples.jsonl`: every `PEERYARD_SAMPLE_S` (3) s, and at each event (those rows carry `"event": <kind>`; the
  classifier skips them), per node: `state, answered, headersHeight, fullHeight, bestHeaderId, bestFullHeaderId,
  peers, mining` from `/info`, and `pid` (the newest process holding the node's conf path), `loopback_info_ms` (that
  `/info` call's own time over loopback inside the node's namespace, unshaped by netem: the node's REST
  responsiveness, not network latency; `null` with `timeout: true` when it hit its 2 s limit), `cpu_ticks`
  (utime+stime, cumulative), `rss_mb`, `io_read_mb` / `io_write_mb` (cumulative, `/proc/<pid>/io`); per row the host's
  `loadavg1` and `mem_available_mb`. The measurement adds one `/info` call per node per sample, and `/proc` reads.
- `costs.json` (`diag/costs.py`, run after every hook, whatever the verdict; the rig prints `[rig] COSTS <summary>`,
  or `[rig] COSTS ERROR ...` without touching the verdict): per `heal`, `revive` and `relaunch`, `agree_s`, the
  seconds from the event to the first regular sample at which the two nodes' `bestFullHeaderId` are equal and are
  equal again at the next sample (after a revive or relaunch: with each other running node, and the maximum over
  them), or `null` and `censored` with a reason (`endpoint_down`, `next_event`, `never_agreed`), or
  `nothing_to_recover` when the tips were already equal; `height_gap` and `tips_equal_at_event`; after a revive,
  `first_answer_s` (JVM start to REST) and `sync_s = agree_s - first_answer_s`; `headers_advanced_s` per non-mining
  node (an upper bound on link recovery: it includes the wait for the next block; after a revive it is timed from the
  node's first answer with its restored height); CPU seconds and `loopback_info_ms`
  p50/p95/max in the window. Per node: total CPU seconds, peak RSS, and unanswered samples counted as planned (a crash
  or relaunch until the node answers again) or unexpected. `agree_s` has the resolution of the sample interval, and
  under a live miner at 2 s blocks it runs late by a few intervals (two tips read in one sample are rarely of the same
  moment). `costs.json` is a report: no PASS rule reads it. `python3 diag/costs.py <out dir>` re-reads any kept run.
- `messages.jsonl` and `wire/`, only with `PEERYARD_WIRE=1` or `"wire": true` in the topology (off by default): a
  passive capture per link (`diag/wire.py`, on the link's `a` end, both directions), started before the nodes
  launch and stopped after the hook. `wire/<a>-<b>.pcap` holds the packets, and `wire/<a>-<b>.stats.json` the
  kernel's packet and drop counts. They are decoded into `messages.jsonl`: every handshake and frame per link and
  direction, with parsed SyncInfo, Inv, RequestModifier, Modifiers and Peers fields. The rig prints one
  `[rig] WIRE <link>: ...` line per link with the capture drops. Like `costs.json` it is a report: no PASS rule reads it.

Link shaping is set in the topology (`delay_ms`, `loss_pct`, `jitter_ms`, `rate_kbit`; jitter needs a nonzero
delay) and changed live from the hook. `heal` restores exactly what the topology configured for that link. A
link may be **asymmetric**: `delay_ms_ab` / `delay_ms_ba` (and the `_ab`/`_ba` forms of `loss_pct`, `jitter_ms`,
`rate_kbit`) shape the a→b and b→a directions separately, falling back to the symmetric field.

## Generating a topology
`rig/topo.sh <line|star|mesh|clusters> <n> [--delay MS] [--loss PCT] [--jitter MS] [--rate KBIT] [--miners K]
[--chain PRESET] [--bottleneck-delay MS] [--poll 500ms] > topology.json` writes a topology for a shape: a line of n
nodes, a star around node 1, a full mesh, or two clusters joined by one bottleneck link (one miner per cluster).
Each node's `knownPeers` are its link neighbours, so `check_topology` should report every link connected.

## Examples (`examples/`)
| example | nodes | what it checks |
|---|---|---|
| `bringup` | 2 | A mines, B connects and syncs: B is on A's chain at height 3 or more (`same_chain`), the peer sets match the topology, and a live netem change is accepted by `tc` |
| `poscontrol` | 2 | two miners that never peer (the bring-up re-dial is off; checked: neither lists a connected peer) end up on different chains, and `same_chain` reports `DIFF` with both ids read (run it before trusting a "no divergence" result) |
| `floor` | 2 | a sole-peer follower fully syncs, and a restarted node keeps its chain |
| `mining` | 1 | **experimental** (see below): `mine`, quiescence, `start_mining` / `stop_mining` |
| `netsplit` | 2 | `partition` freezes the follower while the miner climbs; `heal` lets it catch up; `crash`, then `revive` while cut from the miner: the follower's height comes back from its own disk (at least the height at the crash, no peer connected), and a second `heal` re-syncs it past that |
| `mixed` | 2 | two jars on one network (`PEERYARD_JAR` mines, `PEERYARD_JAR_B` follows): the follower fully syncs the other version's chain; both appVersions are printed |
| `magic` | 2 | isolation: B runs the devnet default magic `[2,2,4,4]` (a per-node `conf` override) next to A on the rig's `peer` magic `[112,101,101,114]`. Checked from the node logs: each node dials the other (a node that did not is restarted; it re-seeds its peers from its config), and both ends abort every such connection just after the handshake; at the end neither lists a connected peer and the chains differ |
| `txload` | 2 | real transactions: A mines into its wallet, waits out the reward delay, pays B (different keys) 20 times; the payments must be accepted and confirm into B's balance; the non-coinbase transactions in the blocks are counted (fee collection included) |
| `soak` | 2 | a long run whose length is the question's: `PEERYARD_DURATION` seconds of mining at the fixed target, block rate and agreement recorded every minute, optional crash-and-revive of the follower every `SOAK_CRASH_EVERY_MIN` minutes; PASS = past the first height 128 (the version-2 activation reset), same chain, rate within a factor of two of the target, every revive caught up; "same chain" means `same_chain` SAME and `same_state` either `SAME@h` or `LAG@… same-chain` (behind on the miner's chain is fine, A never stops mining); `LAG@… fork`, a `DIFF` root, or a state still unreadable after 30 s of re-sampling fails |
| `hold` | any | keeps a network up until `$SCRATCH/stop` appears; used by `devnet.sh` |
| `txchain` | 1 | a burst of self-payments held in the mempool as a dependency chain (checked: consecutive pooled payments spend the previous one's output), parent listed before child, all confirmed as the slow miner drains the pool (INCONCLUSIVE with no chain in the pool); no mining restart in between, since a restart empties the pool |
| `churn` | 4 | nodes join late (a deferred first launch) and leave (crash) while the chain moves, and must both stay on the miner's chain and catch up to its tip; the final peer sets must match the topology; a `DIFF@h` or a `LAG@… fork` (the lower node's tip not on A's chain) fails, `LAG@… same-chain` is lag |
| `reorg-mempool` | 3 | payments confirmed on the losing side of a fork are re-confirmed on the winning chain after the heal (INCONCLUSIVE when no payment confirmed on the losing side or A and C were not on different chains before the heal); reports reorg depth and time to re-confirm; C must be `SAME@h` or `LAG@… same-chain` with A (a `DIFF`, `LAG@… fork` or `unknown` does not count) |
| `bootstrap-modes` | 3 | a digest-mode follower (no UTXO set, AD proofs; the mode is read from `/info`) and a pruned follower (`blocksToKeep 20`) sync a full miner and agree with it by state root at a settled equal height; the pruned node serves an old header but not its block |
| `matrix-pair` | 2 | two nodes built from ergo's `weak-blocks` line (`PEERYARD_MATRIX_JAR`, chain preset `matrix`): ordering blocks advance, input blocks are produced by the miner and reported by the follower (`/blocks/bestInputBlock`, `/blocks/bestInputChain`), same chain and state at the end; the input-block cadence is reported; PASS needs `same_state` `SAME@h` (sampled up to 120 s for equal heights; a `LAG@…` at the end, same-chain or fork, fails) |
| `matrix-mixed` | 2 | a `weak-blocks` node next to a release node: the release node follows the Matrix miner, then the Matrix node follows the release miner; both logs searched for ban, peer-scoring and invalid-modifier lines about the other side; each direction passes only on `same_state` `SAME@h` at equal heights (a `LAG@…` reading is re-sampled until the window closes, never accepted) |
| `matrix-tx` | 2 | Matrix line: A pays B five times; each payment must be confirmed in an ordering block on both nodes, at least one must be seen inside an input block on A and on B (input-block transactions produced and relayed), and A and B end with the same chain, input chain and state root; per-payment latencies (input block on A, on B, ordering block) are reported |
| `matrix-latency` | 3 | Matrix line in a line topology A - B - C, 150 ms delay and 100 ms jitter per link (netem reorders under jitter): C, two hops from the miner, must receive input blocks, end with A's input chain or a prefix of it (never a different one), and agree with A by header id and state root; input-chain samples are reported as same / prefix / diff. **Needs `patches/ergo-matrix/002`** (relay of received input blocks, ergoplatform/ergo#2566): on plain `weak-blocks` a node relays only the input blocks it mined itself (`// todo: send only id out` in `ErgoNodeViewSynchronizer`, issue #2565), so C sees none (witnessed 2026-09-24: B 206, C 0); with the patch C received 207, 202 and 205 in three PASS runs (2026-09-25) |
| `matrix-fork` | 3 | Matrix line, two miners A and C with B between: the B - C link is cut while both mine (an ordering and input-block fork forms), then healed with C stopped; all three must agree by header id, B's and C's input chains must match A's (or be a prefix), state roots agree; fork depth and the winning side are reported. **Experimental:** on the Matrix reference stack (`patches/stack.sh --build ergo-matrix`: `weak-blocks` + #2505's route + #2566's relay + #2511) it passed 4 of 8 runs (2026-09-25); every FAIL was the lighter side C never taking the heavier chain's headers after the heal (cause `LIGHTER_FORK_NOT_SWITCHING`), diagnosed: a fork deeper than 16 blocks on a young chain leaves no common point in C's V2 sync summary, so the peer answers with an empty continuation. With the `patches/ergo-matrix/004` (a genesis anchor in full summaries, A. Shannon's hunk from an earlier #2511 head, now in #2529 under review; the condition is a chain younger than 128 blocks, as on a devnet or a fresh testnet) it passed 7 of 7 valid runs, 5 of them deep forks (2026-09-25). C is launched pinned to A's genesis, so the two miners cannot start on different chains. On plain `weak-blocks` it does not pass (2026-09-24) |
| `matrix-fork-deep` | 3 | **experimental** (see below): `matrix-fork` with the cut held until the fork is 20 blocks deep (`MATRIX_FORK_DEPTH`); INCONCLUSIVE when it stays shallower |
| `matrix-churn` | 3 | Matrix line: follower B crashes while A keeps producing ordering and input blocks and returns; C joins late at the same moment; both must catch up to A's chain and current input chain, with the same state root; catch-up times are reported |
| `matrix-compat-*` (9) | 2-4 | **experimental**: compatibility and normal operation with several miners, at block version 4 (`PEERYARD_V4=1`): Matrix-only meshes of 2, 3 and 4 miners; two Matrix and two reference nodes with all, only the Matrix, or only the reference nodes mining; Matrix - reference - Matrix in a line; one Matrix among three reference miners; three Matrix and one reference miner. Every node joins A's chain, then the listed miners mine for 8 minutes. PASS = every node on A's chain and state, and no ban or blacklist line; `diag/matrix_compat.py` reports relay among Matrix nodes (with the stale-SyncInfo-height rule of ergoplatform/ergo#2597), ordering blocks and reorgs, input-chain rollbacks, and peer penalties by who penalized whom (peers on an all-Matrix network penalize each other too, so compare with the Matrix-only meshes) |
| `arkadianet-follow` | 2 | a JVM miner on `rust-devnet` and an arkadianet node (`"kind": "arkadianet"`, `PEERYARD_ARKADIANET_BIN`) following it: same header ids, same state root, peers listed by name both ways |
| `ergo-node-rust-follow` | 2 | the same with an ergo-node-rust node (`"kind": "ergo-node-rust"`, `PEERYARD_ERGO_NODE_RUST_BIN`) |
| `arkadianet-mine` | 2 | the reverse: the arkadianet node mines (its candidates solved by the rig's `solve_start` loop at difficulty 1) and the JVM node follows its chain by header id and state root |
| `arkadianet-mine-magic`, `ergo-node-rust-follow-magic` | 2 | the same two runs on the magic `[112,101,101,114]` instead of the Rust devnet's `[7,7,7,7]`: the rig writes the magic override into the Rust node's config, so they need binaries that accept it (proposed upstream) |
| `mempool-evict` | 2 | a 20-transaction mempool sorted by fee per byte: filled with decreasing-fee self-payments, a lower-fee payment is declined, a higher-fee one is accepted and evicts the lowest, the pool drains once mining resumes (`send_fee`); the eviction counts only if A's lowest-fee transaction was in the full pool after the fill and is gone after the high-fee payment with no block in between; INCONCLUSIVE when the probe did not start that way (a self-payment rejected at submission, or a block during the fill or probe) |
| `corruption` | 2 | **experimental** (see below): the follower's data directory is damaged while it is down (`corrupt`: a truncated or zeroed state file, lost undo data, lost history objects) and it is revived: reports refused / recovered / stuck per injury, and a stuck node's state root is compared with the root in the miner's header at its height; PASS = no damaged node serves a state root that differs from the miner's; INCONCLUSIVE when no injury could be applied, or when every damaged node served state that could not be compared |
| `utxo-bootstrap` | 3 | with `makeSnapshotEvery = 128` on every node, a late node with `utxoBootstrap` syncs from a UTXO-set snapshot (two peers can serve it): same state root, no block bodies before the snapshot |
| `loss` | 3 | followers on lossy live links: after bring-up on clean links, A-B gets `PEERYARD_LOSS` % loss both ways (default 3) and A-C 10 % in the block-data direction only (A→C); PASS = within 360 s of the loss, both followers `SAME@h` with A at 30 or more blocks above A's height at the start of the hook, after `settle_follow`; the netem qdiscs are printed from each namespace; costs are reported, not judged |
| `flap` | 2 | a link that comes and goes: `flap A B 10 30 6` while A mines; PASS = `SAME@h` within the window fixed from the flap's start (6 × 40 s + 150 s) at 3 or more blocks above A's height at the last edge; `costs.json` has `agree_s` per cycle (a censored cycle is one in which B and A were not seen on equal tips at two consecutive samples before the next cut) |
| `three-body-close-strong`, `three-body-far-strong` | 3 | Luke Graysmith's three-body shapes, one hook (`three-body.sh`): two nodes 5 ms apart and a third 150 ms from both (no jitter), each pinned with `cpus`: A and B (2 CPUs each) mine with C (1 CPU) following; or C (4 CPUs) mines with A and B (1 each) following. (Two miners on unequal CPUs do not mine at unequal rates here: the devnet difficulty stays at its minimum and each internal miner produces one block per poll.) After a floor and a 20-block prefix, C is cut from A and B for 60 s and healed; the miners run on 180 s (`agree_s` after a partition includes TCP's own recovery), then all but one miner pause and `settle_follow` pauses the last; PASS = all three `SAME@h` at 10 or more blocks above the leader's height at the heal. Each miner's count of locally mined blocks is printed. Needs 5 or 6 CPUs, so it is not in `suite.tsv` (the hosted runners have 2 or 4) |
| `revive-headroom` | 2 | what a restart costs a follower with little CPU: A mines (cpus 0-1), B follows (4-7), B is crashed, A mines on 120 s, and B is revived pinned to `REVIVE_CPUS` (`4`, `4-5` or `4-7`); `costs.json` reports `first_answer_s`, `headers_advanced_s`, `agree_s`, `sync_s`, REST time and CPU seconds for the revive, the launch event the collector (SerialGC at one CPU on JDK 21). These times are read off the sampler's grid (`PEERYARD_SAMPLE_S`, default 3 s), so each is known only to within one interval: `headers_advanced_s` of about one interval is the measure's floor, and `sync_s` (= `agree_s` − `first_answer_s`) inherits both errors; set `PEERYARD_SAMPLE_S=1` for a finer reading; PASS = `SAME@h` at 10 or more blocks above A's height at the revive, after `settle_follow`. Needs 8 CPUs; not in `suite.tsv` |
| `nipopow-bootstrap` | 3 | the same with `nipopowBootstrap` (headers from a NiPoPoW proof, then the snapshot); PASS needs the node's own "processed proof" log line |
| `bringup-phases` | 2 | `bringup`'s claim as a data scenario ([PHASES.md](PHASES.md)); `PHASES_INVERT=1` adds a pass with the expected token flipped, which must FAIL; 3 of 3 PASS hosted, with its original ([sweep](https://github.com/cafebedouin/peeryard/actions/runs/36956276986)) |
| `flap-phases` | 2 | `flap`'s claim as a data scenario, with the same knobs and the same `FLAP_CONTROL=down-edge` control in the file (the settle gets `FLAP_MARGIN_S` itself); 3 of 3 PASS hosted, with its original ([sweep](https://github.com/cafebedouin/peeryard/actions/runs/36956276986)) |
| `reorg-mempool-phases` | 3 | `reorg-mempool`'s claim as a data scenario: the same staging, with the conditions `reorg-mempool` checks together in one loop waited for one after another; 3 of 3 PASS hosted, with its original ([sweep](https://github.com/cafebedouin/peeryard/actions/runs/36956276986)) |
| `reorder-dup-phases` | 3 | payments from a miner to a wallet two hops away while every link direction reorders and duplicates packets (`RD_REORDER`, `RD_DUP`): every accepted payment arrives and the ends agree on chain and state; `RD_CONTROL=cut` cuts the relay before the payments, which must FAIL |
| `mixed-roles-phases` | 3 | a digest and a pruned follower of a full miner through partitions, the digest node killed and revived while cut (it restores its height from disk): both reach the miner's state root at its final height; `MR_CONTROL=down` leaves the digest node down, which must FAIL |

## Experimental examples

`rig/examples/experimental.txt` lists the examples whose FAIL `run-suite.sh` reports as `FAIL (experimental)` and does
not count against the suite. Each has a measured pass rate below 100% and an open investigation; a PASS is still a
PASS, and an example leaves the list when it passes reliably on the reference node. In the three-repeat sweep on GitHub
runners (2026-09-26), every example not listed here passed 3 of 3 (`bootstrap-modes` after its pruning read was made to
retry). The runner counts below pool that sweep, on the public repository's runner class (4 vCPU, 16 GB), with an
earlier one-repeat sweep on the private-repository class (2 vCPU, 8 GB); which class each failure came from was not recorded.

| example | development host | GitHub runners (ubuntu-24.04, 2 and 4 vCPU pooled) | status |
|---|---|---|---|
| `matrix-fork-deep` | 5 of 5 converged (2026-09-25, Matrix stack with `004`) | 2 of 4 (2026-09-26: `LIGHTER_FORK_NOT_SWITCHING` after the heal in the two that failed) | a node-side cause on the `weak-blocks` line is under investigation and will be reported upstream |
| `mining` | passes every sweep | 5 of 7 (2026-09-26: twice a sole node produced no block in its 240 s window; no node log was kept for those two, `run-suite.sh` now keeps them) | cause unknown; the next failure on a runner carries its logs |
| `corruption` | 1 of 1 (2026-09-26 sweep) | 0 of 4 (2026-09-26: the same injury's outcome differed from the development host's every time) | under investigation; the injuries and their outcomes are printed per run |

## Seen to fail

A PASS on the reference node says "nothing broke", not "this would catch a defect", unless the example has been seen to
fail somewhere. Seen so far, and on what (the patch witnesses are in `patches/*/patches.json`; the diffrun scenarios'
release base rates on GitHub runners, 2026-09-27: `fork-convergence` 17 of 40 runs did not switch, `sibling-fork`
20 of 20 diverged; on the reference node 0 of 40 and 0 of 20; details in `diffrun/README.md`):

| example | fails on | seen |
|---|---|---|
| `poscontrol` | by construction: two miners that never peer end on different chains | every run |
| `magic` | a control where B has no known peer (`NOT_BOTH_DIALED`) | control run, 2026-09-26 |
| `netsplit` | a control where B's data directory is wiped before the revive: height 0 for the whole window while cut from A | control run, 2026-09-26 |
| `loss` | a control that partitions A-B instead of the loss (`LOSS_CONTROL=partition`): B never gets a block (`NOHEIGHT`) | control run, 2026-09-27, release 6.0.6 (sha256 `21b90239…`) |
| `flap` | a control that ends on a cut (`FLAP_CONTROL=down-edge`): B stays at A's last-edge height (123) while A climbs | control run, 2026-09-27, release 6.0.6 |
| `three-body-*` | a control that skips the heal (`THREEBODY_CONTROL=no-heal`): C stays at 23 while A reaches 244 | control run, 2026-09-27, release 6.0.6 |
| `revive-headroom` | a control that revives B while it is partitioned from A (`REVIVE_CONTROL=partitioned`) | control run, 2026-09-27, release 6.0.6 |
| `reorg-mempool` | the 6.0.6 release without `patches/ergo/002`: 3 of 10 payments re-confirmed (10 of 10 with it) | patch witness |
| `nipopow-bootstrap` | the release without `patches/ergo/005`: stalled 2 of 3 | patch witness |
| `matrix-tx` | `weak-blocks` without `patches/ergo-matrix/001`: 3 of 3 FAIL | patch witness |
| `matrix-latency` | without `patches/ergo-matrix/002`: no input blocks reach C | patch witness |
| `matrix-fork`, `matrix-fork-deep` | without `patches/ergo-matrix/003` and `004`: deep-fork runs 0 of 4 | patch witness |

Not yet seen to fail: `bringup`, `floor`, `mining`, `mixed`, `txload`, `txchain`, `churn`, `soak`, `bootstrap-modes`,
`mempool-evict`, `corruption`, `utxo-bootstrap`, `matrix-pair`, `matrix-mixed`, `matrix-churn` and the `arkadianet-*` /
`ergo-node-rust-*` runs. They check bring-up or agreement on the reference node, and their harness steps are guarded
(a partition, crash or restart that did not happen makes the run INCONCLUSIVE, not PASS); a designed failing control
for each is on the roadmap.

The `matrix-*` examples need a jar built from ergo's `weak-blocks` line (the input-chain oracles `same_input_chain` and
`same_input_chain_stable` read its `/blocks/bestInputChain`), and the `ergo-node-rust-follow*` and
`arkadianet-mine-magic` examples need Rust node builds: arkadianet v0.9.0 or later (the magic override shipped there) and an ergo-node-rust build with changes that are proposed upstream but not released
(see *Other implementations*); without those builds, skip them.

## Other implementations (`"kind"`)

A node may be a second implementation of the protocol, launched and observed by the same rig: `"kind":
"arkadianet"` (the Rust node at [arkadianet/ergo](https://github.com/arkadianet/ergo)) or `"kind": "ergo-node-rust"`
([mwaddip/ergo-node-rust](https://github.com/mwaddip/ergo-node-rust)). The rig writes each one's TOML config (data
directory, listen and declared addresses, known peers, REST bind and API key hash, node name), launches the binary
in the node's namespace, and reads the same REST paths it reads on the JVM node: `/info` (`fullHeight`,
`headersHeight`, `bestFullHeaderId`, `stateRoot`, `appVersion`, `name`), `/blocks/at/{h}`, `/peers/connected`
(`name`). So `same_chain`, `same_state`, `check_topology` and `full_height` work unchanged. Both Rust nodes accept
only their compiled-in networks, so such a topology uses the chain preset `rust-devnet`, the private devnet those
binaries define, and the JVM nodes are configured to match it (see *chain* above).

- **arkadianet**: the released binary works as it is. `PEERYARD_ARKADIANET_BIN` names `ergo-node-x86_64-unknown-linux-gnu`
  from the v0.9.0 release (or later: v0.8.0 has `network = "devnet"` but not `[chain] devnet_magic`, which a non-default
  magic needs). It has no internal miner (`use_external_miner`
  must be true), so with `"mining": true` it serves candidates on `/mining/*` and the hook drives them with the
  rig's `solve_start <node>` / `solve_stop <node>` loop (one fixed solution per candidate, valid at difficulty 1;
  `examples/arkadianet-mine`). Its wallet (`/wallet/*`) exists but is not initialized by the rig; the JVM wallet
  helpers are not wired to it.
- **ergo-node-rust**: needs a build with a devnet network. The released binaries (v0.8.2) know only `mainnet` and
  `testnet`, with magic and genesis compiled in. A small change adding `[proxy] network = "devnet"` (the same
  parameters as arkadianet's devnet) is proposed upstream; until it merges, build the node from that branch and
  point `PEERYARD_ERGO_NODE_RUST_BIN` at `target/release/ergo-node-rust`. The rig's config for it uses the
  `[node] api_address` and `[listen.ipv4]` keys of its `ergo.toml.example`. It has no wallet API.

Mixed-implementation runs ask for **agreement**: the same chain and the same state root under honest traffic. A
disagreement between implementations is a finding for the implementations' maintainers, reported to them
privately first (`SECURITY.md`).

## Snapshot starts: reusing a long prefix (`PEERYARD_FIXTURES`)

Some examples spend most of a run building the same prefix before the part under test starts: `utxo-bootstrap`
and `nipopow-bootstrap` mine ~270-340 blocks, mature rewards, mint boxes and wait for a UTXO snapshot (85% and 65%
of the run on a GitHub-hosted runner), while `reorg-mempool` spends only 19% on setup. With
`PEERYARD_FIXTURES=<dir>` set, a hook that calls `fixture_save k=v ...` where its prefix ends has the rig stop the
running nodes gracefully, archive their data dirs and the given values, and relaunch them; a later run with the
same key restores the data dirs before bring-up, sets the values again, and the hook skips its prefix:

```bash
if fixture_restored; then
  echo "prefix restored: snapshot at $snap"
else
  ...build the prefix...
  fixture_save snap="$snap" snap_a="$snap_a"
fi
```

The key covers every node's jar (sha256), the topology, the hook and the chain settings, so any change to them
builds a new fixture. `PEERYARD_FIXTURE_MODE=rebuild` ignores a saved one. Unset, nothing changes.

## A devnet that stays up (`rig/devnet.sh`)

```
PEERYARD_JAR=~/ergo-6.0.6.jar bash rig/devnet.sh up rig/examples/soak.json mynet
bash rig/devnet.sh status mynet                # rig alive, heights, versions
bash rig/devnet.sh curl A /info mynet          # any node's REST API from your shell
bash rig/devnet.sh logs B mynet
bash rig/devnet.sh down mynet                  # nodes stop; the chain is kept
bash rig/devnet.sh up rig/examples/soak.json mynet   # continues from where it stopped
bash rig/devnet.sh wipe mynet
bash rig/devnet.sh expose B 19052 mynet       # http://127.0.0.1:19052 -> B's REST, for a panel, explorer or wallet on the host (python3)
bash rig/devnet.sh unexpose B 19052 mynet

# two versions on one persistent devnet: the release jar mines, a candidate follows (rig/examples/mixed.json)
PEERYARD_JAR=~/ergo-6.0.6.jar PEERYARD_JAR_B=~/ergo-candidate.jar bash rig/devnet.sh up rig/examples/mixed.json two
```
The nodes live in the rig's unprivileged namespaces; `curl` enters them with `nsenter` (allowed for the user who
created them, no root). State lives under `~/.peeryard/devnet/<name>` (or `PEERYARD_DEVNET_DIR`): the topology,
`out/` with logs and `effective.json`, and the nodes' data directories. Nodes are stopped gracefully so their
databases flush, and `up` after `down` resumes every node's chain from its data directory, whatever the chain
preset; only `wipe` deletes it.

## Configured from the caller, recorded in the run

Every run writes `out/effective.json`: the chain preset and its resolved parameters, the Java runtime (`java
-version`, the binary, the options), every node's jar and its sha256 (`jar_sha256`, and the prefix `jar_sha256_16`), mining and polling, the external
miner (`external_miner`: poll and rate, or null), every link's
shaping, the duration and keep-data flags, and a `host` card: `kernel`, `cpus_online`, `affinity` (the rig's own
CPU mask; a run under `taskset` shows it), `mem_mb`, `cpu_model`, `virt` (`wsl2` when `/proc/version` names
Microsoft, else `systemd-detect-virt`), `scratch_fs` (`stat -f` type of `SCRATCH`; ext4 reads `ext2/ext3`),
`scratch_virtual_disk` (true under WSL2, whose disks are image files), `tcp_cc` and `tcp_retries2` (read inside a
node's namespace). It also holds each node's identity address (`nodes[].id_ip`), each link's two addresses
(`links[].a_ip`, `b_ip`), and `wire`: `enabled`, and with the wire on, the capture's `cpus`, whether they are
`pinned`, and whether they `overlaps_node_cpus`. Environment
overrides shape a run without editing the topology: `PEERYARD_CHAIN` (preset), `PEERYARD_MINE_POLL` (default
polling for miners that set none), `PEERYARD_EXTMINE_POLL` / `PEERYARD_EXTMINE_RATE` (external miners instead of
the internal CPU miner, see *Hook helpers*), `PEERYARD_DURATION` (hooks that run for a while read it),
`PEERYARD_KEEP_DATA=1` (do not wipe data directories on first launch), `PEERYARD_WIRE=1` (the wire capture),
`PEERYARD_JAVA` (the `java` binary for
JVM nodes; the node is built and tested on JDK 8, so pin one to compare with upstream's numbers),
`PEERYARD_JAVA_OPTS` (default `-Xmx512m`), and `PEERYARD_UP_TIMEOUT` (seconds a node may take to answer at
bring-up, default 60; a node that never answers aborts the run with a named error instead of running the hook
on a half-up network). A result should carry the effective
configuration next to it: a verdict without the network it ran on is not comparable to another.

`bash rig/preflight.sh [nodes]` checks the host without starting a node: user namespaces, netem in a namespace,
the commands, the Java runtime and its version, free memory for that many JVMs. Then run `poscontrol` and
`floor` first on a new machine or a new node version. If they fail, results built on
top of them mean nothing.

The hooks compare chains with `same_chain` (header ids at the lower of two heights), never by tip equality: a
node that follows a live miner is always a block or two behind, which is lag, not a fork.

**In a container:** the rig needs unprivileged user namespaces, which Docker's default seccomp and AppArmor
profiles block. Run the container with `--security-opt seccomp=unconfined --security-opt apparmor=unconfined`
(no `--privileged` and no root inside are needed); the host must have `sch_netem` loaded.
