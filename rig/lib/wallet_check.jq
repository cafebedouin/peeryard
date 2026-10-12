# wallet_check.jq: the invariants of the wallet workload (rig/WALLET-WORKLOAD.md), judged from one step's observation.
# The driver (rig/lib/wallet_workload.sh) only collects; every PASS/FAIL comes from here, so the no-node self-test
# (tests/wallet_workload.sh) exercises the same code a node run does.
#
#   jq -c -L rig/lib 'include "wallet_check"; judge' <observation.json>
#
# An observation is {step, kind, arg, control, setup, ...kind fields}. `setup` non-null means the step could not
# be exercised (INCONCLUSIVE). Output: {step, kind, arg, verdict: PASS|FAIL|INCONCLUSIVE, setup, invariants: [{name,
# ok, value}], info: {...}}. A step FAILs when any invariant is false. Amounts are nanoERG or raw token units.

def inv($name; $ok; $value): {name: $name, ok: $ok, value: ($value | if type == "string" then . else tojson end)};
def num: type == "number";
def nonneg: num and . >= 0;
# token sums of a list of boxes ({assets: [{tokenId, amount}]}) as {tokenId: total}
def token_sums: reduce (.[]?.assets[]?) as $a ({}; .[$a.tokenId] += $a.amount);
def sub_maps($a; $b): ($a + $b | keys_unsorted | unique) as $k | reduce $k[] as $t ({}; .[$t] = (($a[$t] // 0) - ($b[$t] // 0)));
def nonzero: with_entries(select(.value != 0));

# inputs of every transaction body in .txs ({id: {inputs: [boxId]}}) that also appear in .scan_boxes
def scan_spends: (.scan_boxes // []) as $s
  | if ($s | length) == 0 then [] else [(.txs // {}) | to_entries[] | .key as $id | .value.inputs[]? | select(. as $b | $s | index($b)) | {tx: $id, box: .}] end;
def scan_inv: if ((.scan_boxes // []) | length) == 0 then [] else [scan_spends as $x | inv("no_scan_box_spent"; ($x | length) == 0; if ($x | length) == 0 then "\(.scan_boxes | length) scan-only boxes, none among \((.txs // {}) | length) transactions' inputs" else $x end)] end;

# chain/pool/state checks shared by resubmit and conflict
def no_stall: . as $o | [(.start_heights // {}) | to_entries[] | . as $e | select(($e.value | num | not) or (($o.end_heights[$e.key] // 0) <= $e.value)) | $e.key] as $s
  | inv("no_stall"; ($s | length) == 0 and ((.start_heights // {}) | length) > 0; if ($s | length) == 0 then "every node advanced: \(.start_heights | tojson) -> \(.end_heights | tojson)" else "no progress on \($s | join(",")): \(.start_heights | tojson) -> \(.end_heights | tojson)" end);
def one_state: (.agree // "") as $a | inv("one_state_root"; ($a | test("^SAME@")) or ($a | test("^LAG@[0-9,]+ same-chain")); $a);
def gone_from_pools($ids): [(.pools_end // {}) | to_entries[] | .key as $n | .value[]? | select(. as $t | $ids | index($t)) | "\($n):\(.[0:8])"] as $left
  | inv("gone_from_pools"; ($left | length) == 0 and ((.pools_end // {}) | length) > 0; if ($left | length) == 0 then "no pool holds \($ids | map(.[0:8]) | join(","))\(if .clear_s then " (cleared after s: " + (.clear_s | tojson) + ")" else "" end)" else "still pooled at the deadline: \($left | join(" "))" end);

def check_send:
  . as $o
  | [.requests[]? | select(.id != null)] as $acc
  | [.requests[]? | select(.id == null)] as $rej
  | ($acc | map(.id) | unique) as $ids
  | [$ids[] as $id | ($o.txs[$id].inputs // [])[] | {box: ., tx: $id}] as $pairs
  | ($pairs | group_by(.box) | map(select(length > 1) | {box: .[0].box[0:16], txs: map(.tx[0:8])})) as $shared
  | [$ids[] | select(($o.confirmed // {})[.] == null)] as $unconf
  | [$ids[] | select(($o.txs // {})[.] == null)] as $nobody
  | {setup: (if ($acc | length) == 0 then "no payment accepted (\($rej | length) rejected: \($rej[0].reason // "" | .[0:160]))" else null end),
     invariants: ([
       inv("distinct_inputs"; ($shared | length) == 0 and ($nobody | length) == 0; if ($nobody | length) > 0 then "no body found for \($nobody | map(.[0:8]) | join(",")) (inputs unknown)" elif ($shared | length) == 0 then "\($ids | length) accepted, \($pairs | length) inputs, none shared" else $shared end),
       inv("accepted_confirmed"; ($unconf | length) == 0; "\(($ids | length) - ($unconf | length))/\($ids | length) confirmed\(if ($unconf | length) > 0 then "; not confirmed: " + ($unconf | map(.[0:8]) | join(",")) else "" end)"),
       inv("rejected_with_reason"; all($rej[]; (.reason // "") | length > 0); "\($rej | length) rejected, \([$rej[] | select((.reason // "") | length > 0)] | length) with a reason")
     ] + scan_inv),
     info: {accepted: ($ids | length), duplicate_ids: (($acc | length) - ($ids | length)), rejected: ($rej | length),
            race_rejects: ([$rej[] | select((.reason // "") | test("already in the mempool|double.?spen|spent|conflict"; "i"))] | length),
            first_reason: ($rej[0].reason // null | if . then .[0:200] else null end)}};

def check_mint:
  (.tx // {}) as $tx | (.input_tokens // {}) as $in
  | [($tx.outputs // []) | token_sums | to_entries[] | select($in[.key] == null)] as $new
  | {setup: (if ($tx.id // null) == null then "no transaction generated: \(.reason // "" | .[0:200])" else null end),
     invariants: ([
       inv("token_id_is_first_input"; ($new | length) == 1 and $new[0].key == ($tx.inputs[0] // ""); "new token \($new | map(.key[0:16]) | join(",")), first input \($tx.inputs[0] // "" | .[0:16])"),
       inv("minted_amount"; ($new | length) == 1 and $new[0].value == .request.amount; "minted \($new | map(.value) | tojson), requested \(.request.amount)"),
       inv("confirmed"; .confirmed | num; "submit \(.submitted // .reason // "" | .[0:120]); confirmed at \(.confirmed)"),
       inv("wallet_holds_minted"; ($new | length) == 1 and ((.wallet_after // {})[$new[0].key // ""] == .request.amount); "wallet holds \((.wallet_after // {})[$new[0].key // ""] // 0) of it")
     ] + scan_inv),
     info: {token: ($new[0].key // null)}};

def check_transfer:
  (sub_maps(.tx_in_tokens // {}; .tx_out_tokens // {}) | nonzero) as $diff
  | {setup: (if (.token // null) == null then "no token to transfer (no mint step before it)" elif (.tx.id // null) == null then "no transaction generated: \(.reason // "" | .[0:200])" else null end),
     invariants: ([
       inv("tx_tokens_conserved"; ($diff | length) == 0; if ($diff | length) == 0 then "every token: inputs == outputs" else $diff end),
       inv("confirmed"; .confirmed | num; "confirmed at \(.confirmed)"),
       inv("sender_delta"; (.sender_before - .sender_after) == .amount; "sender \(.sender_before) -> \(.sender_after) (expected -\(.amount))"),
       inv("receiver_delta"; (.receiver_after - .receiver_before) == .amount; "receiver \(.receiver_before) -> \(.receiver_after) (expected +\(.amount))")
     ] + scan_inv), info: {}};

def check_burn:
  (sub_maps(.tx_in_tokens // {}; .tx_out_tokens // {}) | nonzero) as $diff
  | (.wallet_before // {}) as $wb | (.wallet_after // {}) as $wa
  | (sub_maps($wb.tokens // {}; $wa.tokens // {}) | nonzero) as $wd
  | .token as $t | .amount as $amt
  | {setup: (if ($t // null) == null then "no token to burn (no mint step before it)" elif (.tx.id // null) == null then "no transaction generated: \(.reason // "" | .[0:200])" else null end),
     invariants: ([
       inv("tx_burns_exactly"; $diff == {($t // ""): $amt}; "inputs - outputs per token: \($diff | tojson) (expected {\($t // "" | .[0:16])…: \($amt)})"),
       inv("tx_erg_conserved"; .tx_in_erg == .tx_out_erg; "ERG in \(.tx_in_erg), out \(.tx_out_erg) (fee output included)"),
       inv("confirmed"; .confirmed | num; "confirmed at \(.confirmed)"),
       inv("wallet_burned_exactly"; $wd == {($t // ""): $amt}; "wallet token change: \($wd | tojson)"),
       inv("wallet_erg_only_fee"; ($wb.erg - $wa.erg) == .fee; "wallet ERG \($wb.erg) -> \($wa.erg) (expected -\(.fee))")
     ] + (if .control == "positive" then [inv("control_burned_amount_still_there"; (($wa.tokens // {})[$t // ""] // 0) == (($wb.tokens // {})[$t // ""] // 0); "positive control: must FAIL; before \(($wb.tokens // {})[$t // ""] // 0), after \(($wa.tokens // {})[$t // ""] // 0)")] else [] end)
       + scan_inv), info: {}};

def check_scan:
  . as $o
  | {setup: (if .interaction != "off" then "scan not registered with walletInteraction off (got \(.interaction // "nothing"))" elif ((.scan_boxes // []) | length) == 0 then "no box tracked by the scan" elif ([.sends[]? | select(.id != null or (.reason // "") != "")] | length) == 0 then "no wallet send attempted" else null end),
   invariants: [
     inv("scan_tracks_boxes"; ((.scan_boxes // []) | length) >= (.expected_boxes // 1); "\(.scan_boxes // [] | length) tracked (\(.unconfirmed_scan_boxes // [] | length) unconfirmed), expected \(.expected_boxes // 1)"),
     ([.sends[]? | select(.id != null) | .id as $id | .inputs[]? | select(. as $b | ($o.scan_boxes // []) | index($b)) | {send: $id[0:8], box: .[0:16]}] as $x
      | inv("no_scan_box_spent"; ($x | length) == 0; if ($x | length) == 0 then "\([.sends[]? | select(.id != null)] | length) sends accepted, \([.sends[]? | select(.id == null)] | length) refused; no scan-only box among their inputs" else $x end))
   ],
   info: {sends: [.sends[]? | {label, accepted: (.id != null), reason: (.reason // null | if . then .[0:160] else null end)}],
          balance_with_unconfirmed_counts_scan_box: (.balance_includes_scan // null)}};

def check_fee:
  def series($k): [.[$k][]?];
  (series("getFee") | sort_by(.wait)) as $gf | (series("waitTime") | sort_by(.fee)) as $wt
  | {setup: (if ($gf | length) == 0 and ($wt | length) == 0 then "no fee endpoint answered" else null end),
     invariants: [
       inv("present"; all($gf[]; .fee | num) and all($wt[]; .ms | num) and (.hist | type) == "array"; "getFee \($gf | map(.fee) | tojson), waitTime \($wt | map(.ms) | tojson), histogram bins \(.hist | if type == "array" then length else "absent" end)"),
       inv("non_negative"; all($gf[]; .fee | nonneg) and all($wt[]; .ms | nonneg) and all(.hist[]?; (.nTxns | nonneg) and (.totalFee | nonneg)); "all fee, wait and histogram values >= 0"),
       inv("getFee_monotone"; [range(1; $gf | length) as $i | $gf[$i].fee <= $gf[$i - 1].fee] | all; "fee by wait (min): \($gf | map("\(.wait)=\(.fee)") | join(" ")) (longer wait -> fee not higher)"),
       inv("waitTime_monotone"; [range(1; $wt | length) as $i | $wt[$i].ms <= $wt[$i - 1].ms] | all; "wait (ms) by fee: \($wt | map("\(.fee)=\(.ms)") | join(" ")) (higher fee -> wait not longer)")
     ],
     info: {pool_size: .pool_size, histogram_txns: ([.hist[]?.nTxns] | add)}};

def check_resubmit:
  .id as $id
  | [(.chain // {}) | to_entries[] | select((.value | length) != 1) | "\(.key):\(.value | length)"] as $bad
  | ([(.chain // {}) | .[] | .[0]] | unique) as $hs
  | {setup: (if ($id // null) == null then "no transaction generated: \(.reason // "" | .[0:200])" elif (.submits[0].reply_id // null) == null then "the first node refused its own wallet's transaction: \(.submits[0].reason // "" | .[0:200])" else null end),
     invariants: [
       inv("confirmed_once_everywhere"; ($bad | length) == 0 and ((.chain // {}) | length) > 0 and ($hs | length) == 1; if ($bad | length) == 0 then "in every node's chain once, at height \($hs | join(","))" else "times in chain: \($bad | join(" "))" end),
       gone_from_pools([$id // ""]), no_stall, one_state
     ],
     info: {lag_s: .lag_s, two_accepted: ([.submits[]? | select(.reply_id != null)] | length == 2), second_reply: (.submits[1].reply_id // .submits[1].reason // null | if . then .[0:120] else null end)}};

def check_conflict:
  (.ids // []) as $ids
  | [(.chain // {}) | to_entries[] | {node: .key, n1: (.value[$ids[0] // ""] // [] | length), n2: (.value[$ids[1] // ""] // [] | length)}] as $c
  | [$c[] | if .n1 == 1 and .n2 == 0 then "t1" elif .n2 == 1 and .n1 == 0 then "t2" else "bad(\(.n1),\(.n2))" end] as $w
  | {setup: (if ($ids | length) != 2 or ($ids[0] // null) == null or ($ids[1] // null) == null then "two transactions were not generated: \(.reason // "" | .[0:200])" elif $ids[0] == $ids[1] then "the two wallets built the same transaction" elif ([.submits[]? | select(.reply_id != null)] | length) == 0 then "neither node accepted its transaction" else null end),
     invariants: [
       inv("exactly_one_confirmed"; ($c | length) > 0 and ($w | unique | length) == 1 and ($w[0] | test("^t[12]$")); "per node: \([$c[] | "\(.node)=\(.n1)/\(.n2)"] | join(" ")) (t1/t2 occurrences in its chain)"),
       gone_from_pools($ids), no_stall, one_state
     ],
     info: {in_flight: ([.submits[]? | select(.reply_id != null)] | length), winner: ($w[0] // null), clear_s: (.clear_s // null),
            replies: [.submits[]? | {node, ok: (.reply_id != null), reason: (.reason // null | if . then .[0:120] else null end)}]}};

def judge:
  . as $o
  | (if .setup != null then {setup: .setup, invariants: [], info: {}}
     else (if .kind == "send" or .kind == "send-par" then check_send
           elif .kind == "mint" then check_mint
           elif .kind == "transfer" then check_transfer
           elif .kind == "burn" then check_burn
           elif .kind == "scan" then check_scan
           elif .kind == "fee" then check_fee
           elif .kind == "resubmit" then check_resubmit
           elif .kind == "conflict" then check_conflict
           else {setup: "unknown step kind \(.kind)", invariants: [], info: {}} end) end) as $r
  | {step: $o.step, kind: $o.kind, arg: ($o.arg // null), control: ($o.control // "none"),
     verdict: (if $r.setup != null then "INCONCLUSIVE" elif all($r.invariants[]; .ok) then "PASS" else "FAIL" end),
     setup: $r.setup, invariants: (if $r.setup != null then [] else $r.invariants end), info: $r.info};   # a step that could not be exercised judges nothing

# summary over judged steps (one per line, slurped): the run's verdict and the RESULT_JSON metrics
def summarize:
  . as $s
  | ([.[] | select(.control == "positive")] | length > 0) as $ctl
  | ([.[] | .invariants[]? | select(.name | startswith("control_")) | select(.ok == false)] | length > 0) as $tripped
  | ([.[] | select(.verdict == "FAIL") | select([.invariants[] | select(.ok == false) | select(.name | startswith("control_") | not)] | length > 0)] | length) as $real_fail
  | {steps: length, pass: ([.[] | select(.verdict == "PASS")] | length), fail: ([.[] | select(.verdict == "FAIL")] | length),
     inconclusive: ([.[] | select(.verdict == "INCONCLUSIVE")] | length), real_fail: $real_fail,
     control: (if $ctl then "positive" else "none" end), control_tripped: $tripped,
     conflict_runs: ([.[] | select(.kind == "conflict" and .verdict != "INCONCLUSIVE")] | length),
     conflict_two_in_flight: ([.[] | select(.kind == "conflict" and .info.in_flight == 2)] | length),
     resubmit_runs: ([.[] | select(.kind == "resubmit" and .verdict != "INCONCLUSIVE")] | length),
     resubmit_two_accepted: ([.[] | select(.kind == "resubmit" and .info.two_accepted == true)] | length)}
  | .verdict = (if .control == "positive" then (if .control_tripped and .real_fail == 0 then "CONTROL-TRIPPED" else "CONTROL-NOT-TRIPPED" end)
                elif .fail > 0 then "FAIL" elif .inconclusive > 0 or .steps == 0 then "INCONCLUSIVE" else "PASS" end)
  | .pass_all = (.verdict == "PASS");
