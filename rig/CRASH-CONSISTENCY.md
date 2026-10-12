# crash-consistency: a node killed mid-write must come back where its peers are

A node that loses power or is killed while it writes blocks has to restart from whatever reached its disk: history,
UTXO state, undo data and (optionally) the extra indexer, possibly out of step with one another. The honest outcome is
that, once it is back and synced, it holds exactly the chain and the state an untouched peer holds. `crash-consistency`
stages that case on a live network and checks it: a subject node S is killed with SIGKILL at random points while it is
applying blocks, restarted from its own disk each time, and then compared with an untouched follower R and the miner M.

It is a general instrument: the kill points, the number of kills, S's role (full follower, digest, pruned, miner) and the
indexer are parameters. Applies to (first uses): ergoplatform/ergo#2675 "Preserve valid fork continuations during history
repair", #2541 "Recover paired history insertions before exposing stored objects", #2523 "Propagate history repair
failures before publishing recovered state", #2548 "Improved repair after DB corruption". The kills are ordinary process
deaths of an honest node (`CONTRIBUTING.md`); nothing is written into the node's files (for damage done to the files of
a stopped node, see the `corruption` example).

Files:

| file | what |
|---|---|
| `rig/examples/crash-consistency.json` | topology: M mines (`mine_poll` 500 ms); R and S follow M on their own links; R and S are deferred, so the hook sets S's role (and the indexer) before their first launch |
| `rig/examples/crash-consistency.sh` | the hook: bursts, kills, restarts, the settle, the final samples, the log search, the observation file and `RESULT_JSON` |
| `rig/crash-verdict.sh` | the outcome classifier: one observation file in, one `CRASH-CONSISTENCY ...` line out |
| `tests/crash_consistency.sh`, `tests/fixtures/crash-consistency/` | the classifier's no-node self-test |
| `rig/lib/indexer.sh`, `rig/indexer-cmp.sh` | the extra-indexer snapshot and comparator (from the `indexer-diff` branch), used with `CC_INDEXER=1` |
| `diffrun/scenarios/crash-consistency.{sh,json}` | the diffrun scenario (base vs candidate; every node on the role's jar), runnable by `pr-scenario.yml` |

## What is killed, and when

S is made to apply a **burst** of blocks, and each kill lands inside a burst:

1. **Floor**: R and S on M's chain at height 5 or more. The M -> S link is limited to `CC_RATE_KBIT` (256) kbit/s for
   the whole run (re-applied after every heal), which spreads the header download of a burst over a few seconds
   (`CC_RATE_KBIT=0` turns it off).
2. **Burst 1**: the M - S link is cut until M is `CC_BACKLOG` (60) blocks above S, then healed; S resumes syncing when its
   connection recovers (up to about 50 s after the heal, a TCP retransmission backoff, not the node).
3. **Kill k** (k = 1 .. K): at the kill point (below), after a random wait of 0 .. `CC_JITTER_MS` (50) ms, `crash S`
   (SIGKILL to the node's process, checked gone).
4. **Burst k+1**: S stays down until M is `CC_BACKLOG` blocks above S's height at the kill, then S is restarted from its
   own data directory (`revive`); the restart is reported (below), and the next burst is S catching up from there.
5. After kill K, S is restarted once more (a miner subject with mining off) and settles.

**The kill point** (`CC_KILL`):
- `height` (default; not for the miner role): a target height drawn uniformly inside the burst (from S's height at the
  burst's start to M's height then, both ends excluded); the kill follows once S writes that height in its log:
  `CC_KILL_ON=full` reads `applied to UtxoState at height <h>` (digest role: `Got new full block <id> at height <h>`),
  `CC_KILL_ON=indexed` reads the extra indexer's `Buffered block <h> / ...` (v6.0.7 strings; `CC_TRIGGER_RE`, an ERE with
  one group, overrides). The log is the trigger because REST cannot keep up: on the development host S applied a
  60-block backlog between two `/info` reads 0.1 s apart (2026-10-11, v6.0.7), so a REST-polled trigger landed after
  the burst every time. The hook tails the log in the background from just before the burst starts; the jitter then
  spreads the kill over the next few blocks' writes instead of always just after the logged one.
- `time` (default for the miner role): a delay drawn from `CC_KILL_MIN_MS` .. `CC_KILL_MAX_MS` (0 .. 8000) ms after the
  burst's start (the heal, or S answering REST after a restart), so a kill can land while S is still reloading its chain.

Every random choice comes from bash's `RANDOM` seeded with `CC_SEED` (default: from the clock), printed on the first line
(`[cc] seed=<n> kills=<K> ...`). The number of kills K is drawn from 3-5 unless `CC_KILLS` is set. Each kill draws the
height fraction, the jitter and the delay whatever the mode, so one seed gives the same choices in either mode. A seed fixes
the choices, not the moments: the block S is writing when the signal arrives depends on timing.

**Inside the window**: after the kill, the hook reads from S's log what S had written since the burst started: its last
applied block, best header and indexer height. A kill counts as inside the burst when that last applied block is above
the burst's start and at least two blocks below M's height at the kill (two blocks of ordinary follower lag behind a live
miner do not count as a burst); with `CC_KILL_ON=indexed`, the same for the indexer's last buffered height, against where
the indexer stood before the burst (not against S's applied block: the indexer reads full blocks from history, which after
a kill can be ahead of the state; seen: indexer at 128 while the state's last applied block was 76, 2026-10-11). Fewer than `CC_MIN_IN_WINDOW` (ceil(K/2)) kills inside makes the run INCONCLUSIVE.

**Per kill** the hook prints and keeps (`<log dir>/crash-consistency/kills.jsonl`): the trigger (`height@<h logged>`,
`time` or `timeout`), the target or delay, the jitter, the epoch-ms moment and the ms from the burst's start, S's last
applied block, best header and indexer height as its log shows them, M's height, and `in_window`. **Per restart**:
whether S came back (answered REST within `CC_UP_S`, 180 s), the ms to REST, the height it resumed from (the first block
it applies after the restart, minus one) against its last applied block before the kill, and `startup`: whether its log
says the node found state and history out of step at startup (`State and history are inconsistent`) and what it did
(`inconsistent-rolled-back`, `inconsistent-recovered-from-headers` for a digest node, `none`). That last field is what
shows a kill really landed between the node's history and state writes: on the v6.0.7 release (2026-10-11, development
host) most restarts of a full follower reported it (3 or 4 of the 4 restarts in each run), and the digest run's restarts
recovered from headers. A digest node that recovers from headers resumes above the last block it logged (seen: killed at
125 and 139, resumed at 138 and 192, its best header), since it takes the state roots from the headers it already holds.

**Where a kill lands.** The trigger is a log line the node writes after a block's state is applied, and the kill follows
within the jitter (0-50 ms), during which S applies a few more blocks (seen: 0-7). So the kills fall at arbitrary points of
the next few blocks' writes, not uniformly over everything the node does: a kill inside a single large write (a big
block, a snapshot, an indexer flush) needs `CC_KILL=time` or another `CC_TRIGGER_RE`.

## S's role and the indexer

`CC_ROLE`: `follower` (default, UTXO state, all blocks kept), `digest` (`stateType = digest`), `pruned`
(`blocksToKeep = CC_KEEP`, 20), `miner` (S mines too, at `CC_SUBJECT_POLL`, 1 s, alongside M; its final restart is with
mining off so it settles onto M's chain). R stays a full follower in every role: digest and pruned nodes report the same
UTXO state root as a full node at the same block.

`CC_INDEXER=1` turns `ergo.node.extraIndex` on for S and R. After S, R and M agree, the hook waits up to 180 s for both
indexers to reach their full height, snapshots both (`rig/lib/indexer.sh`: every box and transaction by global index,
the range listings, tokens, per-address balances and listings) and compares them with `rig/indexer-cmp.sh`; its settle rule
applies (a snapshot that moved while read, an indexer behind, a 503 or 5xx is INCONCLUSIVE, never SAME). With
`CC_KILL_ON=indexed` the kills land while the indexer catches up.

## Settle rule and verdict

After the last restart S has to settle: `settle_follow M S <M's height>` (rig `hook_api.sh`): M drops to a slow
poll (20 s), S must reach `same_state` `SAME@h` at an equal height between blocks within `CC_SETTLE_S` (240) s, then M
pauses. Then, with M paused, the hook takes a sample every 3 s for up to `CC_FINAL_S` (90) s, stopping at the first one in
which S, R and M agree: per node one `/info` read (answered, full and header height, best full and best header id, state
root), plus R's and M's header ids at S's full height. All samples, the kills, the log lines and the indexer line go into
`<log dir>/crash-consistency/obs.json`, and `rig/crash-verdict.sh` prints the outcome (first match):

| outcome | when |
|---|---|
| `INCONCLUSIVE <reason>` | a harness or staging failure (a crash that did not kill, a floor not reached), fewer kills done than planned, fewer inside the window than required, no sample, an indexer comparison that did not settle, or R and M disagreeing with each other at the end |
| `REFUSED` | S does not answer REST in the last sample (the line says whether it answered earlier) |
| `DIFF@h` | in any sample, S and R or M at an equal full height with a different best full block id or state root; or S's best full block not the block R or M holds at S's height; or the indexer comparator's DIFF (`DIFF@indexer <field>`) |
| `SAME@h:<id>` | in the last sample S, R and M at one full height with one best full block and one state root, and no unrecoverable line in S's log |
| `LOGERR@h` | as SAME, but S's log holds a line matching `CC_FATAL_RE` (default: `Failed to recover state`, `NodeViewHolder failed`, `Attempted node view holder restart`, `Rollback failed`, the extra indexer's stop, restart and rollback errors, `OutOfMemoryError`, `Exception in thread`) |
| `STUCK@<full>/<headers>` | otherwise: S answers, holds nothing that conflicts, and does not agree within the window |

Every ERROR line in S's log is also counted and the five most frequent are printed (reported, not judged). The rig verdict
is PASS on SAME, FAIL on DIFF, LOGERR, STUCK or REFUSED, INCONCLUSIVE otherwise. The `RESULT_JSON` metrics are `same`,
`diff`, `stuck`, `refused`, `logerr`, `kills`, `kills_in_window`, `max_rest_ms`, `max_rollback` (the largest drop from
the last block applied before a kill to the height resumed from after it), `restarts_inconsistent` (restarts whose log
shows the startup recovery) and `seed`; an INCONCLUSIVE outcome prints an
`INCONCLUSIVE:` line instead, so diffrun counts the run as setup, not evidence.

## Controls

`CC_CONTROL` selects one; each prints `[cc] control <name>: expected <OUTCOME>, got <OUTCOME>: as expected | NOT AS EXPECTED`.

- `aa`: the same bursts (burst 1 as above; each later burst is a cut, 5 s for S to apply what it holds, the same
  backlog and a heal, instead of a restart)
  and the same kill points, but nothing is killed. It must be SAME: a non-SAME here is the staging or the comparison, not
  a crash.
- `no-restart`: S is left down after the last kill (the settle runs on R). Must be REFUSED.
- `behind`: after the last restart S is cut from M for the settle and the samples (the settle runs on R). Must be STUCK:
  S behind, on the same chain.
- `fork`: after the last restart S is cut from M and mines three blocks of its own, then the settle runs on R. Must be
  DIFF: S's best full block is not on R's or M's chain.

The classifier's own test (`tests/crash_consistency.sh`) covers every outcome on fixtures; `CRASH_VERDICT=<copy>` runs it
against a broken copy (one that never reports DIFF), which must turn the DIFF cases into MISMATCH.

## Running it

Locally (one network per host: through the lock; three JVM nodes, about 1.1 GB):

```
bash rig/preflight.sh 3
bash review/with-lock.sh -- env PEERYARD_JAR=<jar> CC_SEED=1 bash rig/rig.sh rig/examples/crash-consistency.json rig/examples/crash-consistency.sh
# A/A and the controls
bash review/with-lock.sh -- env PEERYARD_JAR=<jar> CC_CONTROL=aa bash rig/rig.sh rig/examples/crash-consistency.json rig/examples/crash-consistency.sh
bash review/with-lock.sh -- env PEERYARD_JAR=<jar> CC_CONTROL=fork bash rig/rig.sh rig/examples/crash-consistency.json rig/examples/crash-consistency.sh
# another role, the indexer
bash review/with-lock.sh -- env PEERYARD_JAR=<jar> CC_ROLE=digest bash rig/rig.sh ...
bash review/with-lock.sh -- env PEERYARD_JAR=<jar> CC_INDEXER=1 CC_KILL_ON=indexed bash rig/rig.sh ...
# base vs candidate (one pair: the whole network on each jar in turn)
bash review/with-lock.sh -- bash diffrun/run.sh diffrun/scenarios/crash-consistency.json --base <base.jar> --candidate <cand.jar> --out <dir>
```

The knobs reach a diffrun run through the manifest's `env` (strings or numbers); for another role or the indexer, copy the
manifest with its own `env` (`{"CC_ROLE": "digest"}`) rather than editing the shipped one.

On GitHub-hosted runners, `pr-scenario.yml` with `scenario: crash-consistency` (public tier, no sequential rule) builds the
PR's base and the PR and runs the pairs; `aa: true` runs the A/A of the release line there. A verdict is quoted with an A/A
rate for the same predicate (`diffrun/README.md`).

## First runs

Development host (WSL2, 12 CPUs, about 8 GB free), v6.0.7 release jar (sha256 `8616f405…26e9fa`, built from the tag),
JDK 21, 2026-10-11. One run each; a host A/A rate this is not.

| run | hook at | seed | kills (in window) | restarts with `inconsistent` at startup | outcome |
|---|---|---|---|---|---|
| crash | `b5d1460` | 101 | 4 (4) | 4 of 4 (log count) | `SAME@165` |
| crash | `b5d1460` | 202 | 4 (4) | 3 of 4 (log count) | `SAME@196` |
| crash | `b5d1460` | 303 | 4 (4) | 3 of 4 (log count) | `SAME@225` |
| crash | `19250d9` | 404 | 4 (4) | 2 of 4 | `SAME@182` |
| A/A (`CC_CONTROL=aa`) | `b5d1460` | 11 | none (3 points) | - | `SAME@168` |
| A/A (`CC_CONTROL=aa`) | `19250d9` | 12 | none (3 points) | - | `SAME@172` |
| positive control `fork` | `b5d1460` | 21 | 4 (4) | 3 of 4 (log count) | `DIFF@212 off-chain` (expected DIFF) |
| positive control `no-restart` | `b5d1460` | 22 | 5 (5) | 3 of 4 (log count) | `REFUSED` (expected REFUSED) |
| digest (`CC_ROLE=digest`) | `b5d1460` | 31 | 3 (3) | 2 of 3 recovered from headers (log count) | `SAME@209` |
| indexer (`CC_INDEXER=1 CC_KILL_ON=indexed`) | `ab8b3a4` | 42 | 3 (3) | 2 of 3 | `SAME@163`, indexer `SAME` over 14523 fields |
| diffrun A/A pair (the release in both roles) | `b5d1460` | 1713684271, 703247530 | 5 (5) each | - | `SUPPORTS` (both VALID, `same: true`) |

"log count" rows predate the per-restart `startup` field and were counted from `node_S.log` afterwards. Nothing in these
runs logged an unrecoverable line, and S's log held no ERROR line at all (so the log search has not yet been seen to match a real line; the classifier's LOGERR case is covered by its fixture only). The `behind` control and the `pruned` and
`miner` roles have not been run yet.
