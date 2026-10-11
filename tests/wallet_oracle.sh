#!/usr/bin/env bash
# wallet_oracle.sh: tests the wallet oracle's comparator (wallet_cmp in rig/lib/wallet_oracle.sh) on fixture snapshots
# under tests/fixtures/wallet-oracle/: a settled pair that must be SAME, a pair whose reference holds one more box
# (DIFF), a pair one block apart (not settled: INCONCLUSIVE, never DIFF), and variants derived from them with jq, one
# per compared field and one per not-settled reason. The fixtures carry the field shapes and ids of an exploratory
# run on ergo 6.0.6 (trimmed to four boxes and four transactions). No node, a few seconds. Run from the peeryard root:
#   T=$(mktemp -d) bash tests/wallet_oracle.sh
set -uo pipefail
T="${T:?set T to a scratch dir, e.g. T=$(mktemp -d)}"
# T is deleted and recreated below: refuse anything that is not a scratch dir under /tmp or $TMPDIR (where
# mktemp -d puts one), and anything that contains the current directory (T=. from the repo root).
Tr="$(realpath -m -- "$T")"; Tmpr="$(realpath -m -- "${TMPDIR:-/tmp}")"
case "$Tr/" in /tmp/?*/|"$Tmpr"/?*/) ;; *) echo "refusing T='$T': not a scratch dir under /tmp or \$TMPDIR (use T=\$(mktemp -d))" >&2; exit 2 ;; esac
case "$PWD/" in "$Tr"/*) echo "refusing T='$T': it contains the current directory" >&2; exit 2 ;; esac
rm -rf "$T"; mkdir -p "$T"
# shellcheck source=rig/lib/wallet_oracle.sh
source rig/lib/wallet_oracle.sh
F=tests/fixtures/wallet-oracle; S=$F/same-subject.json; R=$F/same-reference.json
fail=0
# case <name> <subject> <reference> <want exit> <want first line, a prefix>
case_(){ local name=$1 s=$2 r=$3 want=$4 line=$5 out rc
  out=$(wallet_cmp "$s" "$r"); rc=$?; echo "$out" > "$T/$name.out"
  if [[ $rc == "$want" && "$(head -1 <<< "$out")" == "$line"* ]]; then res=ok; else res=MISMATCH; fail=1; fi
  printf '%-26s want exit %s [%s...]  got exit %s [%s]  %s\n' "$name" "$want" "$line" "$rc" "$(head -1 <<< "$out")" "$res"; }
v(){ jq "$2" "$R" > "$T/$1.json"; echo "$T/$1.json"; }   # a reference variant

case_ same              "$S" "$R"                        0 "[wallet-oracle] SAME@84:4"
case_ diff              "$S" "$F/diff-reference.json"    1 "[wallet-oracle] DIFF@84: balance: subject="
grep -qF '[wallet-oracle]   unspent: subject=4 (0 only here) reference=5 (1 only here, e.g. 60aa8132)' "$T/diff.out" \
  && echo "diff: the unspent line names the box only the reference holds          ok" \
  || { echo "diff: unspent line                                                     MISMATCH ($(cat "$T/diff.out"))"; fail=1; }
case_ unsettled         "$S" "$F/unsettled-reference.json" 3 "[wallet-oracle] INCONCLUSIVE: not settled: best full blocks differ: subject=84:"
# one variant per compared field: each must be a DIFF naming that field first
case_ diff-addresses    "$S" "$(v ad '.addresses += ["3WwXZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZ"]')" 1 "[wallet-oracle] DIFF@84: addresses: subject=6 (0 only here) reference=7 (1 only here)"
case_ diff-balance-u    "$S" "$(v bu '.balanceUnconfirmed.balance += 1')" 1 "[wallet-oracle] DIFF@84: balanceUnconfirmed:"
case_ diff-box-changed  "$S" "$(v bx '.unspent[0].value += 1')" 1 "[wallet-oracle] DIFF@84: unspent: subject=4 (0 only here, 1 changed"
case_ diff-box-onchain  "$S" "$(v bo '(.unspent[] | select(.onchain | not) | .onchain) = true')" 1 "[wallet-oracle] DIFF@84: unspent:"
case_ diff-tx-height    "$S" "$(v th '.transactions[0].inclusionHeight = 1')" 1 "[wallet-oracle] DIFF@84: transactions: subject=4 (0 only here, 1 changed"
case_ diff-tx-missing   "$S" "$(v tm 'del(.transactions[0])')" 1 "[wallet-oracle] DIFF@84: transactions: subject=4 (1 only here"
case_ diff-scans        "$S" "$(v sc '.scans = [{scanId: 11, scanName: "x"}]')" 1 "[wallet-oracle] DIFF@84: scans: subject=0 (0 only here) reference=1 (1 only here"
case_ same-order        "$S" "$(v or '.unspent |= reverse | .addresses |= reverse | .transactions |= reverse')" 0 "[wallet-oracle] SAME@84:4"   # lists are sets
# each not-settled reason: INCONCLUSIVE, never DIFF, even when the views also differ
case_ ns-mid-read       "$S" "$(v mr '.info_after.fullHeight += 1 | .balance.balance = 0')" 3 "[wallet-oracle] INCONCLUSIVE: not settled: reference /info changed during its snapshot (84 -> 85)"
case_ ns-ref-wallet     "$S" "$(v wh '.walletHeight = 83')" 3 "[wallet-oracle] INCONCLUSIVE: not settled: reference wallet height 83 at full height 84"
case_ ns-wallet-behind  "$(jq '.walletHeight = 80' "$S" > "$T/sw.json"; echo "$T/sw.json")" "$R" 3 "[wallet-oracle] INCONCLUSIVE: not settled: subject wallet height 80 at full height 84"
case_ ns-mempool        "$S" "$(v mp '.mempool = [] | .balanceUnconfirmed = .balance')" 3 "[wallet-oracle] INCONCLUSIVE: not settled: mempools differ: subject=1 reference=0"
WO_IGNORE_MEMPOOL=1 case_ mempool-ignored "$S" "$(v mi '.mempool = []')" 0 "[wallet-oracle] SAME@84:4"   # WO_AT=pending: the pools may differ, the wallets may not
WO_IGNORE_MEMPOOL=1 case_ mempool-ign-diff "$S" "$(v md '.mempool = [] | .balanceUnconfirmed = .balance')" 1 "[wallet-oracle] DIFF@84: balanceUnconfirmed:"
case_ incomplete        "$S" "$(v nu '.unspent = null')" 3 "[wallet-oracle] INCONCLUSIVE: reference snapshot incomplete: unspent"
case_ not-json          "$S" "$(echo 'oops' > "$T/bad.json"; echo "$T/bad.json")" 3 "[wallet-oracle] INCONCLUSIVE: comparator error"
# the diffrun manifests validate, and diffrun/scenario-env.sh (pr-scenario.yml's scenario_env) sets only declared keys
for m in diffrun/scenarios/wallet-oracle-restart.json diffrun/scenarios/wallet-oracle-fork.json; do
  e=$(jq -c -L diffrun/lib 'include "diffrun"; validate_manifest' "$m"); [[ "$e" == "[]" ]] && r=ok || { r="MISMATCH ($e)"; fail=1; }
  echo "manifest $(basename "$m") validates                                $r"; done
cp diffrun/scenarios/wallet-oracle-restart.json "$T/m.json"
se(){ local want=$1 spec=$2 rc; bash diffrun/scenario-env.sh "$T/m.json" "$spec" > "$T/se.out" 2>&1; rc=$?
  [[ $rc == "$want" ]] && r=ok || { r="MISMATCH ($(cat "$T/se.out"))"; fail=1; }
  printf 'scenario-env %-34s want exit %s got %s  %s\n' "'$spec'" "$want" "$rc" "$r"; }
se 0 'WO_AT=pending; WO_EVENTS=restart crash'
[[ "$(jq -c .env "$T/m.json")" == '{"WO_EXAMPLE":"restart","WO_EVENTS":"restart crash","WO_AT":"pending"}' ]] && echo "scenario-env: env after the override                              ok" || { echo "scenario-env: env MISMATCH $(jq -c .env "$T/m.json")"; fail=1; }
se 1 'WO_UNKNOWN=1'
se 1 'WO_AT=$(id)'
se 0 ''
[[ $fail == 0 ]] && echo "wallet oracle tests: all ok" || { echo "wallet oracle tests: MISMATCH (see $T)"; exit 1; }
