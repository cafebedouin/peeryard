# diag/: reading what the runs left behind

Tools over the logs a run keeps. They name candidates; they do not prove causes. A candidate becomes a claim
when a test that forces the named state passes and fails as predicted, and the run a public claim rests on is made
on a GitHub-hosted runner (a development machine discovers; the runs a claim rests on are made where anyone can re-run them).
All are standard-library Python and have tests in `tests/` (wired into `tests/tooling.sh` and CI).

| tool | question | input | output |
|---|---|---|---|
| `diagnose.py` | why did this run miss its goal? | one run's sampled `/info` (`samples.jsonl`), and beside it `events.jsonl` + `effective.json` (cuts) and `messages.jsonl` (the wire) when present | a named cause (node down, stalled, lighter fork not switching, partitioned, ...) in `verdict.json`; a lighter fork's wire stage |
| `features.py` | which per-run feature separates the runs that failed from those that passed? | run dirs + outcome labels (or each run's verdict line) | features ranked by separation (perfect split first, then AUC), with ranges per outcome |
| `sweep.py` | which runs look unlike the others, or show something never seen before? | a tree of run dirs, no labels; optionally earlier runs as a baseline | per run: rare messages, count outliers, feature outliers; with `--baseline`: new messages, new transitions, new co-occurrences, features outside the known range |
| `logmap.py` | which line of the node's source wrote this log line? | a node source checkout | an index of `log.<level>(...)` calls; `--source` on `features.py` and `sweep.py` names the code behind each finding |
| `costs.py` | what did recovery cost? | a rig run's `events.jsonl` + `samples.jsonl` | `costs.json`: per heal, revive and relaunch, the seconds to agreement (equal tips at two consecutive samples), first answer and CPU in the window; a one-line summary |
| `matrix_prop.py` | how far and how fast do Matrix input blocks travel? | the `messages.jsonl` of `matrix-latency` runs with the wire on | per run and per arm: the share of A's input blocks that reach C, the hop latency, duplicates per link (`.github/workflows/matrix-relay.yml`) |
| `matrix_value.py` | what did Matrix input blocks carry, cost on the wire and fetch again? | a matrix-compat run (or patch-compare artifact) with the wire on and a payment load: `messages.jsonl`, node logs, `txwatch.jsonl`, `txload*.jsonl` | per run: bytes per minute per sending node by message group and type (and to Matrix vs reference peers); BlockTransactions requests per received ordering block (wire, by section id; and from the logs, without the wire); merged-uncle transactions split into duplicates and unique; every sibling's transactions by fate (on the winning path, merged, re-included later, none); pool size and block fill (`.github/workflows/patch-compare.yml` `wire` input) |
| `health.py` | did a node fail during the run, whatever the verdict? | a rig run's node logs (and `events.jsonl`), or a patch-compare run artifact (`nodes/node_<X>.log.gz`, or the counted `errors-node_<X>.txt`) | per node: unplanned process exits, OutOfMemoryError, JVM fatal errors, restart loops (one supervisor-restart message 20+ times); `HEALTH: OK` or `HEALTH: UNHEALTHY <node>=<CODE>`; the rig runs it after every hook and judges it (`rig/README.md`, *Hook helpers*); `--watch` is the rig's exit watcher; `compare_pool.py` and `.github/workflows/health-recheck.yml` apply it to earlier runs |
| `block_invariants.py` | did any block a node held break an invariant? | `blocks.jsonl` from `rig/lib/blockwatch.sh` | violations of `link`, `body`, `once`, `pool`, `agree` and each contract check (a command per block), with node, height and reason; `INVARIANTS: OK` or `VIOLATED` |
| `mutation_judge.py` | does a test notice that a change is gone? | spec-compare job artifacts of an unmutated arm and a mutant arm (`patches/mutate.sh`) | `MUTATION: KILLED` (control passes everywhere, mutant fails everywhere), `SURVIVED` or `INVALID` |
| `wire.py` | what did the nodes actually send each other? | a rig run with the wire on (`PEERYARD_WIRE=1`): one pcap per link | `messages.jsonl`: every P2P message per link and direction, on the rig's clock, with drops and decode gaps counted |

## How they fit

1. A batch of runs fails some of the time. `diagnose.py` has already named each failure's end state.
2. **Known split** (you can label the runs): `features.py --labels runs.tsv` ranks the features that separate
   them. Retro-check: blind, it re-found the two discriminators found by hand on 2026-09-25 (a follower's header
   lead at stop, 6-7 vs 0-5, behind a CI hang; a chain switch's first step, 13-25 vs 32-47, behind lost
   mempool transactions).
3. **No split yet, or looking for anything new**: `sweep.py <runs> --baseline <earlier runs>` lists what these runs
   show that none before did. Read every item and keep or discard it; a checked batch can join the baseline, so
   the next sweep shows only what is new again. Novelty is a search: the list is candidates, not findings.
   Within one batch (no baseline) the sweep ranks anomalies instead; a failure mode that hits a large share of
   runs is not rare, so label the runs and use `features.py` for it.
4. Add `--source <node checkout>` to either tool to see the code line behind each message or feature
   (about 92% of the templates in a 60-run corpus map to one line; the rest are Akka's own logs or messages built
   indirectly).

```
python3 diag/features.py --labels runs.tsv --target hung --source ~/src/ergo
python3 diag/sweep.py new-runs/ --baseline old-runs/ --source ~/src/ergo
python3 diag/logmap.py find ~/src/ergo '10:04:05.505 WARN  [x] o.e.n.ErgoModifiersCache - Modifier ab.. is permanently invalid ...'
```

## Wire observer (`wire.py`)

A node does not log what it sends, so from `/info` and the logs a run shows effects, never the exchange. `wire.py`
records the exchange. It is passive: it opens a packet socket that only reads, and it never sends, injects or alters
a packet.

- **Capture** (in the rig, opt-in: `PEERYARD_WIRE=1` or `"wire": true` in the topology; off by default): one
  process per link, on the link's `a` end, inside that node's namespace. It sees both directions. It starts before
  the nodes launch and writes `out/wire/<a>-<b>.pcap` in libpcap format (Ethernet), readable by tcpdump and
  Wireshark: tcpdump 4.99.4 and tshark 4.2.2 read the golden fixture (161 packets; one TCP conversation of 153
  packets) and a fork-convergence capture (424 packets) with the same packet counts as the decoder, and `<a>-<b>.stats.json`: the kernel's packet and drop
  counts (`PACKET_STATISTICS`, read each second into a series), the socket buffer (raised to `net.core.rmem_max`),
  and the skew between the kernel's receive time and the time written. What the `a` end sees is what crossed the link:
  its egress is tapped after netem. In `netsplit`, no packet was captured inside either cut window, over a connection
  that lived through the cut. The capture runs on CPUs no node's `cpus` names when a topology pins nodes; otherwise it
  shares CPUs with the nodes (`effective.json` `wire` records which).
- **Decode** (`python3 diag/wire.py decode <out dir>`; the rig runs it after the hook): TCP streams are reassembled
  by sequence number per connection and direction. The handshake, which is not framed, is parsed structurally. Then
  come frames: magic, code, length, then checksum and data when the length is above zero. Each frame's checksum is
  verified. The output is `out/messages.jsonl`, one record per message: `{t_ms, kind, link, conn, from, to, ...}`
  with kind `handshake` (agent, version, node name, features), `frame` (code, name, len, checksum_ok, and parsed
  fields for SyncInfo 65, Inv 55, RequestModifier 22, Modifiers 33, GetPeers 1 and Peers 2: sync version, header
  counts and heights, type ids and counts, and `modifier_ids` (hex) on Inv, RequestModifier and Modifiers, so an
  announced modifier can be followed through its request and delivery), and `gap`, `desync`, `resync` and `tail` for what could not be decoded.
  Also `out/wire/summary.json`, one line per link printed as `[rig] WIRE ...`. `t_ms` is on the same epoch-ms clock
  as `events.jsonl`.
- **Matrix (weak-blocks line)**: `InputBlock` (100), `InputBlockTxIds` (102), `InputBlockTxs` (104),
  `InputBlockTxsRequest` (105) and `OrderingBlock` (106) are parsed, per the weak-blocks serializers at `a1bd938e`:
  input- and ordering-block ids (the Blake2b-256 of the header, as the node computes them), heights, the parent input
  block, and the weak (6-byte) transaction ids. Checked on a `matrix-latency` capture: 309 Matrix frames, no parse
  error, every input block's parent id is one this decoder computed from another announcement, and all 271 ids
  appear in the nodes' own logs. Also parsed: an input block's ordering parent (the header's parentId); from announcement
  version 2, the length of the new fields and, when they read as the uncles prototype's field (a count of at most 2,
  then 32-byte ids), `uncle_ids`; and per ordering block (106) and per delivered header (Modifiers 101) the id of its
  BlockTransactions section (`tx_section_id(s)`: Blake2b-256 of 102, the header id and its transactionsRoot), so a
  type-102 RequestModifier can be tied to the block it fetches. On the golden capture every delivered header's computed
  section id is one the nodes named on the wire (tests/wire_test.py).
- **A gap is a loss of capture, not of traffic**: a hole the receiver acknowledged but the capture never saw. A
  direction the capture never saw at all (no SYN and no payload) is found the same way, from the other side's acks, and
  is a `gap` with `"unseen": true`; `matrix_prop.py` leaves a run with a gap on a counted direction out of the pool. Every
  summary prints the capture drops beside it. An absence ("no Inv was sent") holds only where the links and window
  show no gap and no drop, and `diagnose.py` marks a wire stage `unreliable` otherwise.
- **First consumer**: `diagnose.py` splits `LIGHTER_FORK_NOT_SWITCHING` by what crossed the lower node's links to the
  higher chain after its last height change. The stages are `NO_SYNC`, `SYNC_NO_INV`, `INV_NOT_REQUESTED`,
  `REQUEST_NOT_ANSWERED` and `DELIVERED_NO_HEIGHT_CHANGE`. They are descriptive: no stage claims a code-level reason.
  At the time of writing this split has unit tests only. It has not yet named a stage on a real run.
- **Public and private**: the capture and the decoder are public capability. Capture files stay in the run's log
  directory, and CI never uploads raw pcaps; an example uploads `messages.jsonl` summaries only when it opts in, and may
  add the capture's health files (`*.stats.json`, `summary.json`, `capture.log`: counts, no traffic). A
  capture that documents a private reproduction or an undisclosed defect stays with whoever holds that report: the
  embargo binds the detail, not the capability.

## Limits

- Log-derived features depend on the node's log lines; a renamed message silently drops a feature. `logmap.py`
  run against the jar's source catches that (the line stops mapping).
- A run dir is any directory holding `node_<X>.log(.gz)` or `...-node<NN>-<container>.log`; a log directory named
  `ci-logs`, `logs` or `out` stands for its parent. Several logs for one node (a restart per container) are keyed
  `<node>#1`, `<node>#2` by first timestamp.
- The wire capture has been measured at light load only: `txload` (about 40 packets/s) with 0 drops, the same verdict
  and about the same wall time as without it. Read a heavier run with its per-second drop series. The capture is
  Python, one packet per system call. Kernel receive time and the recorded time differed by under 1 ms there.
- The wire parsers follow the v6.0.6 reference node's layouts. A layout change in another implementation or version
  may show up as `parse_error` fields or desyncs, but a shifted field can also parse as a wrong number. Before trusting
  a new version's decode, capture a golden fixture of it (as `tests/fixtures/wire-bringup.*` does for 6.0.6).
- Rates from a batch are bounds, not verdicts: report "0 of 20, rate below ~14% at 95%", and pre-register the n.
