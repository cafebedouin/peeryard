#!/usr/bin/env bash
# tests/rig_setup_check.sh: ci/rig-setup-check.sh, as patch-compare's run step uses it after a stubbed rig, and the
# pool step's SETUP ERROR line. Only a setup error (rig exit 2) or a run with no node log fails; exits 0, 1 and 3
# (PASS, FAIL, INCONCLUSIVE: the experiment ran) pass through. Run from the peeryard root: T=$(mktemp -d) bash tests/rig_setup_check.sh
set -uo pipefail
T="${T:?set T to a scratch dir}"; fail=0
# the run step's shape: stub rig with exit code $1, node logs present ($2 = 1) or not, then the guard (bash -e, as Actions)
step(){ local code=$1 logs=$2 run="$T/runs/r$1$2"; mkdir -p "$run/nodes"
  [[ $logs == 1 ]] && echo x | gzip > "$run/nodes/node_A.log.gz"
  bash -eo pipefail -c '
    run="$1"; code="$2"
    stub_rig(){ echo "[rig] stub"; return "$code"; }
    stub_rig > "$run/rig.log" 2>&1 || rc=$?
    echo "rig exit ${rc:-0}" >/dev/null
    bash ci/rig-setup-check.sh "${rc:-0}" "$run" >/dev/null' _ "$run" "$code"; echo $?; }
check(){ local name=$1 want=$2 got=$3 marker=$4
  [[ "$got" == "$want" ]] && r=ok || { r=MISMATCH; fail=1; }
  printf '%-34s step exit want %s got %s  SETUP-ERROR %s  %s\n' "$name" "$want" "$got" "$marker" "$r"; }
for c in 0 1 3 2; do g=$(step $c 1); m=$([[ -f "$T/runs/r${c}1/SETUP-ERROR" ]] && echo written || echo absent)
  check "rig exit $c, node logs" "$([[ $c == 2 ]] && echo 1 || echo 0)" "$g" "$m"; done
g=$(step 0 0); check "rig exit 0, no node log" 1 "$g" "$([[ -f "$T/runs/r00/SETUP-ERROR" ]] && echo written || echo absent)"
# the pool step: a SETUP-ERROR marker in any run fails it and is named
mkdir -p "$T/art/p1-v4-1" "$T/art/p2-v4-1"; cp "$T/runs/r21/SETUP-ERROR" "$T/art/p1-v4-1/"
pool(){ ( cd "$T" && bash -eo pipefail -c '
  { echo pooled; for f in art/*/SETUP-ERROR; do [ -f "$f" ] && echo "SETUP ERROR, not a verdict: $(basename "$(dirname "$f")"): $(head -1 "$f")"; done; echo end; } > pooled.txt
  ! grep -q "^SETUP ERROR" pooled.txt' ); echo $?; }
check "pool with a setup-error run" 1 "$(pool)" "$(grep -c '^SETUP ERROR' "$T/pooled.txt") line"
rm "$T/art/p1-v4-1/SETUP-ERROR"; check "pool without one" 0 "$(pool)" "$(grep -c '^SETUP ERROR' "$T/pooled.txt") line"
# the workflow carries the same three pieces this test runs
W=.github/workflows/patch-compare.yml
for pat in '> "$run/rig.log" 2>&1 || rc=$?' 'bash ci/rig-setup-check.sh "${rc:-0}" "$run"' "! grep -q '^SETUP ERROR' pooled.txt"; do
  grep -qF -- "$pat" "$W" && printf '%-34s present  ok\n' "workflow: ${pat:0:28}" || { printf '%-34s MISSING\n' "workflow: ${pat:0:28}"; fail=1; }; done
[[ $fail == 0 ]] && echo "rig setup check: all ok" || { echo "rig setup check: MISMATCH"; exit 1; }
