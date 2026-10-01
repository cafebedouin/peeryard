# Hook API

Call forms, printed lines and side effects for helpers a hook can use once `rig.sh` has sourced it. What each helper is for is in [Hook helpers](README.md#hook-helpers). Events they append are in [Events, samples, costs and the wire](README.md#events-samples-costs-and-the-wire).

The first group is every helper in `rig/lib/hook_api.sh` that a hook calls. The second is every helper in `rig.sh` that at least three examples call. A `[rig] HARNESS-FAIL <message>` line reports a failed change; the rig keeps the message and the verdict becomes INCONCLUSIVE. The call under each heading is only a shape.

## rest

`rest <node> <path>` runs `curl -s --max-time 4` in the node's namespace and prints the body. The status is curl's.

`rest A /info`
Used in: `bringup.sh`, `floor.sh`, `soak.sh`.

## same_chain

`same_chain <a> <b>` prints one line and returns 0. `<h>` is the lower of the two full heights. The line is `NOHEIGHT` when `<h>` is below 1, `NOID@<h>:<a>=<id>:<b>=<id>` when either header id at `<h>` is empty, `SAME@<h>:<id>` when the ids match, or `DIFF@<h>:<a>=<id>:<b>=<id>` when they differ.

`same_chain A B`
Used in: `bringup.sh`, `soak.sh`, `poscontrol.sh`.

## link_netem

`link_netem <a> <b> <spec>` replaces the netem qdisc on `<a>`'s veth toward `<b>`. `<spec>` is one argument, split into `tc` netem words. Success prints nothing and records a `link_netem` event whose detail is `<spec>`. With no link, stderr is `[rig] no link <a><-><b>` and the status is 1, with no event. When `tc` fails, the line is `[rig] HARNESS-FAIL netem '<spec>' on <a>-><b> not applied`, the status is 1, and there is no event.

`link_netem A B "delay 40ms"`
Used in: `bringup.sh`, `loss.sh`.

## partition

`partition <a> <b>` sets `loss 100%` both ways. Success sets `PARTITIONED` for both orders of the pair, records a `partition` event (detail is `EVENT_DETAIL`, empty when unset) and prints `[rig] partition <a><-><b> (100% loss)`, plus ` (<detail>)` when `EVENT_DETAIL` is set. No link prints `[rig] HARNESS-FAIL partition <a> <b>: no such link` and returns 1. If either direction fails, the return is 1 and the event, the flag and the success line are skipped; a failure of the second leaves the first already at `loss 100%`.

`partition A B`
Used in: `netsplit.sh`, `matrix-fork.sh`, `reorg-mempool.sh`.

## heal

`heal <a> <b>` restores each direction's configured netem spec, unsets `PARTITIONED` both ways, records a `heal` event and prints `[rig] heal <a><-><b>`, plus ` (<detail>)` when `EVENT_DETAIL` is set. No link prints `[rig] HARNESS-FAIL heal <a> <b>: no such link` and returns 1. If either direction fails, the return is 1 and the event, the flag and the success line are skipped; a failure of the second leaves the first already restored.

`heal A B`
Used in: `netsplit.sh`, `matrix-fork.sh`, `three-body.sh`.

## same_state

`same_state <a> <b>` reads `/info` on both nodes, prints one line and returns 0. `NOHEIGHT` when either full height is below 1. When the heights differ the line is `LAG@<ha>,<hb> unknown`, `LAG@<ha>,<hb> same-chain` or `LAG@<ha>,<hb> fork`: the heights stay in argument order, and the word after the space says whether the lower node's `bestFullHeaderId` equals the other node's header id at that height (`unknown` when either id is empty). At equal heights the line is `NOROOT@<h>:<a>=<root>:<b>=<root>` when either root is empty, `SAME@<h>:<root>` when they match, or `DIFF@<h>:<a>=<root>:<b>=<root>` when they differ.

`same_state A B`
Used in: `matrix-pair.sh`, `soak.sh`, `loss.sh`.

## settle_follow

`settle_follow <leader> <follower> <min_h> [window_s]` (the window defaults to 150). Call it directly, not in `$(...)`, so the relaunch bookkeeping (PID, mining overrides) stays in the caller's shell. Stdout from the two mining restarts is discarded. It returns 0 when `same_state` prints `SAME@<h>:<root>` with `<h>` at least `<min_h>` inside the window, and 1 on `DIFF@...` or when the window ends. `LAG@...`, `NOHEIGHT` and `NOROOT@...` keep the poll going, every 3 seconds.

It restarts the leader with mining on at `${SETTLE_POLL:-20s}`, waits up to 60 seconds for a full height of at least 1, polls, then stops mining and waits for the height again. Each restart records a `relaunch` event and a `launch` event. It sets `SETTLE_STATE` to the deciding line, `SETTLE_TRICKLE` to the leader's full height at the decision minus the height taken before the first restart, `SETTLE_WAIT_S` to the seconds from the end of that first wait until the decision, and `SETTLE_AFTER` to `same_state` after the stop. Why the leader keeps mining is in [Hook helpers](README.md#hook-helpers).

`settle_follow A B 30 150`
Used in: `loss.sh`, `flap.sh`, `three-body.sh`.

## full_height

`full_height <node>` prints `.fullHeight` from `/info`, or `0` when that field is absent. The status is the pipeline's.

`full_height A`
Used in: `bringup.sh`, `soak.sh`, `netsplit.sh`.

## header_at

`header_at <node> <height>` prints the first header id from `/blocks/at/<height>`, or nothing when there is no first id. The status is the pipeline's.

`header_at A 1`
Used in: `matrix-tx.sh`, `matrix-fork.sh`, `bootstrap-modes.sh`.

## check_topology

`check_topology` prints one line per link, then a line for each connected peer with no link. It returns 0 when every unpartitioned link is mutual and every peer has a link, and 1 on any miss. A partitioned link is printed and leaves the status unchanged. The lines are `  link <a><-><b>: partitioned (not expected connected)`, `  link <a><-><b>: connected both ways`, `  link <a><-><b>: MISSING (<a> sees:<peers> | <b> sees:<peers>)` (`<peers>` is empty, or a space and the connected names) and `  node <n>: connected to <p> WITHOUT a link`.

`check_topology`
Used in: `bringup.sh`, `churn.sh`, `soak.sh`.

## check_topology_wait

`check_topology_wait [seconds]` retries `check_topology` with its output discarded, every 3 seconds, until it returns 0 or the seconds run out (default 60), then prints one `check_topology`. The status is that last call.

`check_topology_wait 60`
Used in: `matrix-pair.sh`, `matrix-fork.sh`, `matrix-mixed.sh`.

## data_mb

`data_mb <node>` prints the data-directory size in megabytes, or nothing when `du` cannot read it.

`data_mb A`
Used in: `soak.sh`, `flap.sh`, `loss.sh`.

## input_chain_ids

`input_chain_ids <node>` prints the `bestInputBlocks` ids from `/blocks/bestInputChain`, one per line, or nothing when the list is empty or the route is missing.

`input_chain_ids A`
Used in: `matrix-tx.sh`, `matrix-latency.sh`, `matrix-fork.sh`.

## same_input_chain_stable

`same_input_chain_stable <a> <b> [tries]` (tries default to 60) reads `/blocks/bestInputChain` on `<a>`, then `<b>`, then `<a>` again, and compares only when `<a>`'s two replies are non-empty and identical. Every 0.5 seconds it tries again, until the line is `SAME@...` or the tries run out, then prints that last comparison, or `NONE` when no pair was stable, and returns 0. The comparison line is `NONE` when either ordering id is empty, `DIFF-ORD@<8 hex>/<8 hex>` when the ordering ids differ, `SAME@<8 hex>:<n>` when the input-block lists match, `PREFIX@<8 hex>:A=<na>:B=<nb>` when one list is the tail of the other (the route lists the tip first; the letters A and B are literal, and the counts are `<a>`'s then `<b>`'s), or `DIFF@<8 hex>:A=<na>:B=<nb>` otherwise. `<8 hex>` is the first eight characters of the ordering id, of each id on `DIFF-ORD`.

`same_input_chain_stable A B 60`
Used in: `matrix-tx.sh`, `matrix-latency.sh`, `matrix-fork.sh`.

## block_txs

`block_txs <node> <height>` prints how many transactions that node stores in the block, coinbase included, or `0` when the header id is missing or the block read fails.

`block_txs A 3`
Used in: `txload.sh`, `mempool-evict.sh`, `nipopow-bootstrap.sh`.

## launch

`launch <node>` starts that node. When a `genesisId` pin in its `CONF_OVR` fails the 64-hex check, it prints `[rig] refusing to launch <node>: genesisId pin '<value>' is not a 64-hex block id` and returns 1. The first launch deletes the data directory unless `PEERYARD_KEEP_DATA=1`, then sets `FRESH_DONE` so a later launch keeps the chain. It sets `PID`, appends `==== [rig] (re)launch <node> <time> kind=<kind> jar=<file> mining=<mining> poll=<poll> cpus=<cpus> ====` to the node log (`cfg` when mining or poll is unset, `rig` when the cpu list is unset), prints `[rig] launched <node> (ns=<ns> ip=<ip> p2p=<p2p> rest=<rest> kind=<kind> jar=<file> pid=<pid>)` and `[rig] <node> pid=<pid> cpus_applied=<list>` (`?` when the list was not read; ` gc=<name>` when the probe names a collector), and records a `launch` event.

`launch C`
Used in: `churn.sh`, `matrix-fork.sh`, `nipopow-bootstrap.sh`.

## wait_up

`wait_up <node>` polls `/info` every 2 seconds for `PEERYARD_UP_TIMEOUT` seconds (default 60) until the reply has `appVersion`. It prints `[rig] <node> REST up` and returns 0, or `[rig] WARN <node> never came up` and returns 1 at the deadline.

`wait_up C`
Used in: `churn.sh`, `matrix-fork.sh`, `corruption.sh`.

## crash

`crash <node>` sends SIGKILL to the recorded pid and to any process whose command matches that node's conf path, clears `PID`, records a `crash` event, prints `[rig] crash <node> (SIGKILL, left down)` and returns 0. A process still present first prints `[rig] HARNESS-FAIL crash <node>: its process still runs after SIGKILL`.

`crash B`
Used in: `netsplit.sh`, `soak.sh`, `churn.sh`.

## revive

`revive <node>` prints `[rig] revive <node>`, records a `revive` event, then runs `launch` and `wait_up`, so their lines follow. A node with `FRESH_DONE` already set keeps its data directory. The status is `wait_up`'s.

`revive B`
Used in: `netsplit.sh`, `soak.sh`, `churn.sh`.

## wallet

`wallet <node> <path> [json]` calls that path with header `api_key: hello` and `--max-time 10`. A body is sent as POST with `Content-Type: application/json`; with no body the call is a GET. It prints the body. The status is curl's.

`wallet A /wallet/addresses`
Used in: `arkadianet-mine.sh`, `nipopow-bootstrap.sh`, `mempool-evict.sh`.

## address

`address <node>` prints the wallet's first address, or nothing when the wallet has none.

`address A`
Used in: `txload.sh`, `txchain.sh`, `matrix-txload.sh`.

## pay

`pay <from> <to> <nanoerg>` pays `<to>`'s first address from `<from>`'s wallet. It prints `no address for <to>` and returns 1 when that address is missing. Otherwise it prints the reply when the reply is a JSON string, or else `detail`, or else `reason`, or else the JSON object.

`pay A B 1000000`
Used in: `txload.sh`, `matrix-tx.sh`, `reorg-mempool.sh`.

## wait_balance

`wait_balance <node> <min> [seconds]` polls the wallet balance every 2 seconds (the limit defaults to 240). It prints the balance and returns 0 once the balance is at least `<min>`. At the deadline it prints the last balance, or `0`, and returns 1.

`wait_balance A 1000000000 240`
Used in: `txload.sh`, `txchain.sh`, `nipopow-bootstrap.sh`.

## mint_boxes

`mint_boxes <node> <txs> <outputs> [nanoerg]` sends `<txs>` payments to the node's own first address, `<outputs>` outputs each (1000000 nanoERG when the amount is omitted). It prints `no address for <node>` and returns 1 when that address is missing. A rejected payment prints `[mint] tx <i>: REJECT:<text>`, where `<text>` is `detail`, or else `reason`, or else the JSON. Every tenth payment, and the last, waits up to 120 seconds for an empty mempool. It then prints `minted <accepted>/<txs> txs, <boxes> outputs` and returns 0. `<boxes>` is the accepted count times `<outputs>`.

`mint_boxes A 120 200`
Used in: `nipopow-bootstrap.sh`, `utxo-bootstrap.sh`, `matrix-paychain.sh`.

## start_mining

`start_mining <node> [poll]` sets `MINING_OVR` true and `POLL_OVR` to the poll (default `500ms`), prints `[mine] start_mining(<node> poll=<poll>)` and restarts the node. The restart prints the lines from `launch` and `wait_up`, records a `relaunch` event with detail `mining=true poll=<poll>`, and, when the reloaded full height stays below the height taken before the stop, prints `[rig] <node> reports full height <h> after the relaunch, below its <h0> before it`. No REST answer after the restart prints `[rig] HARNESS-FAIL start_mining <node>: no REST after relaunch`. A JVM node whose `/info` `isMining` differs from `true` prints `[rig] HARNESS-FAIL <node> relaunched with mining=true but /info reports isMining=<got>`, where `<got>` is the reported value, or `nothing` when `isMining` is null. Any other node kind skips that check. The status is the check's.

`start_mining A 500ms`
Used in: `mining.sh`, `corruption.sh`, `matrix-compat.sh`.

## stop_mining

`stop_mining <node>` sets `MINING_OVR` false, leaves `POLL_OVR` as it was, prints `[mine] stop_mining(<node>)` and restarts the node the way `start_mining` does. The `relaunch` detail is `mining=false poll=<poll>`, with `<poll>` the current `POLL_OVR` or `cfg`. No REST answer prints `[rig] HARNESS-FAIL stop_mining <node>: no REST after relaunch`. A JVM node whose `isMining` differs from `false` prints `[rig] HARNESS-FAIL <node> relaunched with mining=false but /info reports isMining=<got>`, where `<got>` is the reported value, or `nothing` when `isMining` is null. The status is the check's.

`stop_mining A`
Used in: `mining.sh`, `corruption.sh`, `matrix-pair.sh`.

## mark

`mark <label>` prints nothing. It records a `mark` event whose detail is `<label>` and whose node and link fields are empty, and one sample row while sampling is on.

`mark flap-start`
Used in: `flap.sh`, `loss.sh`, `matrix-paychain.sh`.
