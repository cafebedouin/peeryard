#!/usr/bin/env bash
# wallet_workload.sh: no-node tests of the wallet-workload invariants (rig/lib/wallet_check.jq through
# rig/wallet-check.sh) on the fixture observations in tests/fixtures/wallet-workload/: for every step kind a PASS
# case and the ways it must FAIL or be INCONCLUSIVE, the positive control, a whole run's summary, the step-list
# parser, and unreadable input. Each case checks the exit code, the step verdict and, for a FAIL, which invariant.
# Run from the peeryard root:
#   T=$(mktemp -d) bash tests/wallet_workload.sh
# WALLET_CHECK_LIB=<dir> tests another copy of wallet_check.jq (the falsifier: a copy whose invariants always hold
# must turn every FAIL case into a MISMATCH).
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2
T="${T:?set T to a scratch dir, e.g. T=$(mktemp -d)}"
Tr="$(realpath -m -- "$T")"; Tmpr="$(realpath -m -- "${TMPDIR:-/tmp}")"
case "$Tr/" in /tmp/?*/|"$Tmpr"/?*/) ;; *) echo "refusing T='$T': not a scratch dir under /tmp or \$TMPDIR (use T=\$(mktemp -d))" >&2; exit 2 ;; esac
case "$PWD/" in "$Tr"/*) echo "refusing T='$T': it contains the current directory" >&2; exit 2 ;; esac
rm -rf "$T"; mkdir -p "$T"
F=tests/fixtures/wallet-workload; fail=0
ok(){ printf '%-58s ok\n' "$1"; }
mis(){ printf '%-58s MISMATCH (%s)\n' "$1" "$2"; fail=1; }
# case_ <fixture> <want exit> <want step verdict> [<invariant that must read FAIL>]
case_(){ local fx="$1" want="$2" verdict="$3" inv="${4:-}" out rc line
  out="$(bash rig/wallet-check.sh "$F/$fx.json" 2> "$T/stderr.txt")"; rc=$?; echo "$out" > "$T/$fx.out"
  line="$(head -1 <<< "$out")"
  if [[ "$rc" != "$want" ]]; then mis "$fx" "exit $rc, want $want: $line"; return; fi
  [[ "$line" == *": $verdict"* ]] || { mis "$fx" "want $verdict in: $line"; return; }
  if [[ -n "$inv" ]]; then grep -qE "^\[ww\]     FAIL $inv:" <<< "$out" || { mis "$fx" "want invariant $inv to FAIL"; return; }
  else ! grep -qE '^\[ww\]     FAIL ' <<< "$out" || { mis "$fx" "an invariant failed: $(grep -m1 'FAIL ' <<< "$out")"; return; }; fi
  ok "$fx -> $verdict${inv:+ ($inv)}"; }

case_ send-par-pass                  0 PASS
case_ send-par-shared-input          1 FAIL distinct_inputs
case_ send-accepted-not-confirmed    1 FAIL accepted_confirmed
case_ send-rejected-without-reason   1 FAIL rejected_with_reason
case_ send-none-accepted             3 INCONCLUSIVE
case_ send-spends-scan-box           1 FAIL no_scan_box_spent
case_ mint-pass                      0 PASS
case_ mint-id-not-first-input        1 FAIL token_id_is_first_input
case_ mint-wrong-amount              1 FAIL minted_amount
case_ mint-not-generated             3 INCONCLUSIVE
case_ transfer-pass                  0 PASS
case_ transfer-receiver-short        1 FAIL receiver_delta
case_ transfer-tx-loses-tokens       1 FAIL tx_tokens_conserved
case_ transfer-no-token              3 INCONCLUSIVE
case_ burn-pass                      0 PASS
case_ burn-takes-another-token       1 FAIL tx_burns_exactly
case_ burn-burns-less                1 FAIL wallet_burned_exactly
case_ burn-wallet-loses-erg          1 FAIL wallet_erg_only_fee
case_ burn-tx-loses-erg              1 FAIL tx_erg_conserved
case_ scan-pass                      0 PASS
case_ scan-probe-spends-scan-box     1 FAIL no_scan_box_spent
case_ scan-not-off                   3 INCONCLUSIVE
case_ scan-tracks-nothing            3 INCONCLUSIVE
case_ fee-pass                       0 PASS
case_ fee-longer-wait-costs-more     1 FAIL getFee_monotone
case_ fee-higher-fee-waits-longer    1 FAIL waitTime_monotone
case_ fee-answer-missing             1 FAIL present
case_ fee-negative-bin               1 FAIL non_negative
case_ resubmit-pass                  0 PASS
case_ resubmit-lag-same-chain        0 PASS
case_ resubmit-missing-on-a-node     1 FAIL confirmed_once_everywhere
case_ resubmit-still-pooled          1 FAIL gone_from_pools
case_ resubmit-first-refused         3 INCONCLUSIVE
case_ conflict-pass                  0 PASS
case_ conflict-split-chains          1 FAIL exactly_one_confirmed
case_ conflict-both-confirmed        1 FAIL exactly_one_confirmed
case_ conflict-loser-lingers         1 FAIL gone_from_pools
case_ conflict-node-stalls           1 FAIL no_stall
case_ conflict-state-roots-differ    1 FAIL one_state_root
case_ conflict-same-tx               3 INCONCLUSIVE

# the positive control: the burn data that passes, judged with the control on, must FAIL on the control invariant only
out="$(bash rig/wallet-check.sh "$F/burn-positive-control.json")"; rc=$?
if [[ $rc == 0 ]] && grep -q '^WALLET-CHECK: CONTROL-TRIPPED' <<< "$out" && grep -q 'FAIL control_burned_amount_still_there' <<< "$out" \
   && [[ "$(grep -c '^\[ww\]     FAIL ' <<< "$out")" == 1 ]]; then ok "positive control -> CONTROL-TRIPPED, only the control fails"
else mis "positive control" "exit $rc: $(grep '^WALLET-CHECK' <<< "$out")"; fi
# a control run whose real invariants also fail is not a tripped control
out="$(bash rig/wallet-check.sh "$F/burn-positive-control.json" "$F/send-par-shared-input.json")"; rc=$?
[[ $rc == 1 ]] && grep -q '^WALLET-CHECK: CONTROL-NOT-TRIPPED' <<< "$out" && ok "control plus a real FAIL -> CONTROL-NOT-TRIPPED" || mis "control plus a real FAIL" "exit $rc"

# a whole run: every PASS fixture together is PASS; one FAIL among them makes the run FAIL; one INCONCLUSIVE, INCONCLUSIVE
passes=("$F"/*-pass.json "$F/resubmit-lag-same-chain.json")
out="$(bash rig/wallet-check.sh "${passes[@]}")"; rc=$?
[[ $rc == 0 ]] && grep -qE '^WALLET-CHECK: PASS .*"steps":9.*"conflict_two_in_flight":1' <<< "$out" && ok "run of ${#passes[@]} passing steps -> PASS, counts" || mis "run of passing steps" "exit $rc: $(grep '^WALLET-CHECK' <<< "$out")"
out="$(bash rig/wallet-check.sh "${passes[@]}" "$F/conflict-loser-lingers.json")"; rc=$?
[[ $rc == 1 ]] && grep -q '^WALLET-CHECK: FAIL' <<< "$out" && ok "... plus one FAIL -> FAIL" || mis "... plus one FAIL" "exit $rc"
out="$(bash rig/wallet-check.sh "${passes[@]}" "$F/scan-not-off.json")"; rc=$?
[[ $rc == 3 ]] && grep -q '^WALLET-CHECK: INCONCLUSIVE' <<< "$out" && ok "... plus one INCONCLUSIVE -> INCONCLUSIVE" || mis "... plus one INCONCLUSIVE" "exit $rc"
echo 'not json' > "$T/bad.json"
bash rig/wallet-check.sh "$T/bad.json" > "$T/bad.out" 2>&1; rc=$?
[[ $rc == 2 ]] && ok "unreadable observation -> exit 2" || mis "unreadable observation" "exit $rc"

# the step-list parser of the driver (rig/lib/wallet_workload.sh, sourced without a node)
# shellcheck source=rig/lib/wallet_workload.sh
source rig/lib/wallet_workload.sh
got="$(ww_expand "send:3, conflict*3 mint" | paste -sd ' ')"
[[ "$got" == "send:3 conflict conflict conflict mint" ]] && ok "step list: separators and repeats" || mis "step list" "got '$got'"
ww_expand "send*x" | grep -q '^BAD:send\*x$' && ok "step list: a bad repeat is reported" || mis "step list: bad repeat" "not reported"
for p in full aa posctl conflict; do ww_preset_steps "$p" > /dev/null || mis "preset $p" "unknown"; done
! ww_preset_steps nosuch > /dev/null && ok "presets: full aa posctl conflict known, others refused" || mis "presets" "an unknown preset was accepted"
ww_preset_steps aa | grep -qE 'send-par|conflict|resubmit' && mis "preset aa" "has a concurrent step" || ok "preset aa has no concurrent step"

[[ $fail == 0 ]] && echo "wallet-workload checker tests: all ok" || { echo "wallet-workload checker tests: MISMATCH (see $T)"; exit 1; }
