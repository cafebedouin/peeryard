# Scenario phases (`rig/lib/phases.sh`)

An optional way to write a rig hook: the scenario is a list of phases, one per line, that `rig/lib/phases.sh` checks
and then runs. It is for hooks that are generic phases plus a pass rule (wait for a floor, act on the network, wait
for agreement, decide). A hook that needs its own observation over many samples, a log, a fixture or an external
oracle stays a shell hook, as every existing example does. Examples: `bringup-phases`, `flap-phases`,
`reorg-mempool-phases` (the same claims as `bringup`, `flap` and `reorg-mempool`).

## The file

A data scenario is an ordinary hook: functions (optional, for `fn`), the `source` line, and one unquoted heredoc.

```bash
# shellcheck source=rig/lib/phases.sh
source "$(dirname "$(readlink -f "$HOOK")")/../lib/phases.sh"
phases <<EOF
wait same_chain A B SAME >= 3 timeout 90
pass topology: topology
EOF
```

The heredoc is unquoted, so a knob such as `${FLAP_DOWN_S:-10}` is expanded by bash when the hook is read. Every knob
carries a default: under `set -u` an unset `$X` stops `rig.sh` (exit 1, read as FAIL) before the checker sees the
text. No other shell goes in the data: `tests/phases.sh` fails on `$(`, a backtick, or a `$NAME` / `${NAME}` without
`:-`, and on any top-level statement other than function definitions, the `source` line and the heredoc.

Lines are numbered from 1 inside the heredoc; blank and `#` lines count. A name (record or label) is
`[a-z_][a-z0-9_]*`; `@name` refers to a recorded value. An expression is digits, `+ - * / ( )` and `@name`
references, evaluated after substitution with no `eval`; `<op>` is one of `== != < <= > >=`.

## Control verbs (they carry the verdict)

| line | meaning |
|---|---|
| `floor <clause> timeout S [cause NAME]` | poll every 3 s until the clause holds; at S seconds (wall clock) the run stops INCONCLUSIVE with `rig_cause` NAME (default `NO_FLOOR`). A setup gate. |
| `wait <clause> timeout S` | the same polling; at S seconds the run stops FAIL, `WAIT_TIMEOUT:<line>`. The claim. |
| `pass [label:] <clause>` | evaluated once, where it stands; the run goes on. Default label `L<line>`. |

The clause is evaluated at least once, so `timeout 0` checks once. The first verdict-bearing event fixes the verdict
and cause: a false `pass` fixes FAIL (`CLAUSE:<label> <value read>`), and a later timeout only stops the run; a floor
timeout, `RECORD_EMPTY` or `EXPR_ERROR` before any false `pass` fixes INCONCLUSIVE. With nothing fixed, the verdict
is PASS when at least one `pass` was evaluated or one `wait` completed, else INCONCLUSIVE `NO_CLAIM_EVALUATED`.
A harness failure still makes `rig.sh` report INCONCLUSIVE, as for any hook.

## Clauses

Each prints the value it read on one `[phases]` line. A token clause is true only on its exact token: `NOHEIGHT`,
`NOID@`, `NOROOT@` and `LAG@… fork|unknown` are false for every clause, so a floor or wait keeps polling.

| clause | true when |
|---|---|
| `same_chain a b SAME\|DIFF [>= expr]` | `same_chain` prints `SAME@h:…` (or `DIFF@h:…`), with h at least expr when given |
| `same_state a b SAME [>= expr]` | `same_state` prints `SAME@h:…`, with h at least expr when given |
| `same_state a b SAME_OR_LAG` | `SAME@…`, or `LAG@ha,hb same-chain` (behind on the same chain) |
| `height n <op> expr` | `full_height n` compares as stated |
| `balance n <op> expr` | the wallet balance compares as stated |
| `value expr <op> expr` | two expressions over recorded values compare as stated |
| `synced n` | full height at least 1 and equal to `/info` `headersHeight` |
| `topology` | `check_topology` returns 0 |
| `settle` | the last `settle_follow` returned 0 (needs a `settle_follow` line before it) |
| `fn NAME [args]` | the hook's function NAME returns 0: the escape hatch for one observation of the hook's own |

## Records, conditions, actions

- `record NAME <reader> [node]`, readers `height <n>`, `balance <n>`, `flap_last` (`FLAP_LAST_HEIGHT`, set by `flap`).
  A reader that prints nothing or a non-number, or a `height` of 0 (the field is absent, as for some seconds after
  a relaunch: put `floor height n > 0 timeout 90` first), stops the run INCONCLUSIVE `RECORD_EMPTY:<name>`.
  `@name` needs an earlier `record NAME` that is not behind a `when`; re-recording a name replaces its value.
- `when VAR=value <phase>`: the phase runs only when the environment variable VAR equals value (VAR matches
  `[A-Z_][A-Z0-9_]*`; no nesting, no else). A skipped `pass` is printed as skipped and left out of the verdict and
  of the metrics. It carries a designed failing control in the same file (`when FLAP_CONTROL=down-edge …`).
- Actions, each one helper of `rig/HOOK_API.md`, run in the hook's own shell (their return status is printed and is
  not part of the verdict; a failed network change is a harness failure as usual): `start_mining n [poll]`,
  `stop_mining n`, `partition a b`, `heal a b`, `link_netem a b <spec…>`, `flap a b down up cycles`,
  `settle_follow leader follower <min_h expr> [window, default 150]`, `pay from to nanoerg [count]` (count payments,
  0.15 s apart; the number accepted is added to the record `pay_sent`), `mark label`, `sleep S`.

## Checked before anything runs

An unknown verb, clause, reader or node, a missing timeout, an `@name` with no earlier unconditional record, an
expression that is not digits and operators or does not evaluate with every `@name` set to 1, a `fn` with no such
function, a duplicate label, a label equal to a record name (`pay_sent` included), a `settle` before any
`settle_follow`, a bad `when`, or a scenario with no `pass` and no `wait` makes the run INCONCLUSIVE with
`rig_cause=BAD_SCENARIO:<line>:<text>` and runs no phase. The message also gives the line in the file.
`PHASES_CHECK=1` checks only; `tests/phases.sh` checks every hook under `rig/examples/` that sources the library.
At run time an expression that cannot be evaluated (division by a recorded 0) stops the run INCONCLUSIVE
`EXPR_ERROR:<line>`. `phases` first sets INCONCLUSIVE `PHASES_ABORTED`, so an error it does not catch still ends named.
On bash 5.2 such an error (an arithmetic error inside a `fn`, say) drops the rest of the hook's current top-level
line, anything chained after the call with `;` or `&&`, and the hook goes on at its next line. So `phases <<EOF … EOF`
stands alone as the hook's last statement, with nothing chained onto it.
`value` with no `@name` on either side compares two constants and is rejected. The check-only pass prints a
`[phases] WARN` (not an error) for an action that follows the last unconditional `pass` or `wait`: nothing observes it.

## Output

`[phases] <i>/<N> <line>` per phase, then `[phases] === <HOOK NAME>: <verdict> ===` (the hook's file name upper-cased:
the suite marker) and one `RESULT_JSON` line in the diffrun envelope: `scenario` the hook's name, `versions` each
node's `appVersion`, `metrics` every evaluated pass label (boolean) and every record (number). `rig.sh` may still turn
the verdict into INCONCLUSIVE after that line (a harness failure); its exit status is the verdict.

## Example: `flap-phases.sh`

```
floor same_chain A B SAME >= 4 timeout 120
mark flap-start
flap A B ${FLAP_DOWN_S:-10} ${FLAP_UP_S:-30} ${FLAP_CYCLES:-6}
record h_last flap_last
when FLAP_CONTROL=down-edge partition A B
when FLAP_CONTROL=down-edge record h_last height A
settle_follow A B @h_last+${FLAP_MARGIN_BLOCKS:-3} ${FLAP_MARGIN_S:-150}
pass settled: settle
```

## Not here (next rows, not implemented: the checker rejects them)

Actions `mine`, `crash`, `revive`, `launch`, `wait_up`, `set_cpus`, `wait_balance`; reader `headers_height`; clause
`peers n == k`. Loops, nesting, else and shell lines in the data are left out on purpose: a scenario that needs them
is a shell hook (or a `fn`). Topology stays in the `.json` file.
