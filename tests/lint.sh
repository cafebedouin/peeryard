#!/usr/bin/env bash
# lint.sh: tests the optional deny-list lint on the no-node stub diffrun/scenarios/test/output-lint-stub, whose
# result carries a term assembled at runtime ("shibb"+"oleth", so this file and the stub pass the input lint
# themselves). Without DIFFRUN_TERMS the verdict is written (exit 0); with a list naming that term the runner
# refuses to write it (exit 5); a list naming a term of the manifest itself is refused before launching (input lint,
# exit 4); a list that cannot be used (unreadable, no term, a bad regex) fails closed (exit 2), never as a pass.
# Run from the peeryard root:
#   T=$(mktemp -d) bash tests/lint.sh
set -uo pipefail
T="${T:?set T to a scratch dir, e.g. T=$(mktemp -d)}"
# T is deleted and recreated below: refuse anything that is not a scratch dir under /tmp or $TMPDIR (where
# mktemp -d puts one), and anything that contains the current directory (T=. from the repo root).
Tr="$(realpath -m -- "$T")"; Tmpr="$(realpath -m -- "${TMPDIR:-/tmp}")"
case "$Tr/" in /tmp/?*/|"$Tmpr"/?*/) ;; *) echo "refusing T='$T': not a scratch dir under /tmp or \$TMPDIR (use T=\$(mktemp -d))" >&2; exit 2 ;; esac
case "$PWD/" in "$Tr"/*) echo "refusing T='$T': it contains the current directory" >&2; exit 2 ;; esac
rm -rf "$T"; mkdir -p "$T"
M=diffrun/scenarios/test/output-lint-stub.json
printf x > "$T/j.jar"; bash diffrun/register.sh -f "$T/j.jar" "0.0.1-$(printf '%s%s' 'shibb' 'oleth')" 2>/dev/null
printf '%s%s\n' 'shibb' 'oleth' > "$T/terms.txt"
fail=0
check(){ local name=$1 want=$2; shift 2
  env "$@" bash diffrun/run.sh "$M" --base "$T/j.jar" --candidate "$T/j.jar" --out "$T/o-$name" > "$T/$name.log" 2>&1; rc=$?
  [[ $rc == "$want" ]] && r=ok || { r=MISMATCH; fail=1; }
  printf '%-10s want exit %s  got %s  verdict.json %s  %s\n' "$name" "$want" "$rc" "$([[ -f $T/o-$name/verdict.json ]] && echo written || echo absent)" "$r"; }
check no-list 0 DIFFRUN_TERMS=
check with-list 5 DIFFRUN_TERMS="$T/terms.txt"
# input lint: a term in the public manifest (its description) refuses the run before any launch
printf '%s\n' 'lint-listed' > "$T/terms-input.txt"
check input-hit 4 DIFFRUN_TERMS="$T/terms-input.txt"
# fail closed: lint.sh exits 2 and run.sh stops with a runner ERROR (exit 2), no verdict
printf '# only a comment\n\n' > "$T/terms-empty.txt"; printf '%s\n' '(unclosed' > "$T/terms-badre.txt"
check unreadable 2 DIFFRUN_TERMS="$T/no-such-terms.txt"
check empty 2 DIFFRUN_TERMS="$T/terms-empty.txt"
check bad-regex 2 DIFFRUN_TERMS="$T/terms-badre.txt"
for c in unreadable:no-such-terms.txt empty:terms-empty.txt bad-regex:terms-badre.txt; do
  DIFFRUN_TERMS="$T/${c#*:}" bash diffrun/lint.sh "$M" > /dev/null 2>&1; rc=$?
  [[ $rc == 2 ]] && r=ok || { r=MISMATCH; fail=1; }
  printf 'lint.sh %-10s want exit 2  got %s  %s\n' "${c%%:*}" "$rc" "$r"; done
# every refusal above wrote nothing
for n in with-list input-hit unreadable empty bad-regex; do
  [[ ! -e "$T/o-$n/verdict.json" ]] || { echo "$n: verdict.json written  MISMATCH"; fail=1; }; done
[[ $fail == 0 ]] && echo "lint tests: all ok" || { echo "lint tests: MISMATCH (see $T)"; exit 1; }
