#!/usr/bin/env bash
# tests/matrix_relay_setup_check.sh: the setup-error guard in .github/workflows/matrix-relay.yml. The run step's shape
# against a stubbed rig (exit 0/1/3 with node logs pass; exit 2 or no node log fail, and the scratch, which holds the
# pcaps, is removed before the step fails), and the workflow's real pool step, extracted from the YAML and run on two
# runs (one that ran, one setup error) with diag/matrix_prop.py. Run from the peeryard root:
#   T=$(mktemp -d) bash tests/matrix_relay_setup_check.sh
set -uo pipefail
T="${T:?set T to a scratch dir}"; fail=0; W=.github/workflows/matrix-relay.yml; ROOT="$PWD"
check(){ [[ "$3" == "$2" ]] && r=ok || { r=MISMATCH; fail=1; }; printf '%-36s want %s got %s  %s  %s\n' "$1" "$2" "$3" "$4" "$r"; }
step(){ local code=$1 logs=$2 run="$T/runs/r$1$2"; mkdir -p "$run/scratch/out/wire"; echo pcap > "$run/scratch/out/wire/A-B.pcap"
  [[ $logs == 1 ]] && echo x > "$run/scratch/out/node_A.log"
  bash -eo pipefail -c '
    run="$1"; code="$2"
    stub_rig(){ echo "[rig] WIRE A-B: stub"; return "$code"; }
    stub_rig > "$run/rig.log" 2>&1 || rc=$?
    echo "rig exit ${rc:-0}" >/dev/null
    bash ci/rig-setup-check.sh "${rc:-0}" "$run" >/dev/null || { rm -rf "$run/scratch"; exit 1; }
    rm -rf "$run/scratch"' _ "$run" "$code"; echo $?; }
for c in 0 1 3 2; do g=$(step $c 1); run="$T/runs/r${c}1"
  check "run step: rig exit $c, node logs" "$([[ $c == 2 ]] && echo 1 || echo 0)" "$g" \
    "SETUP-ERROR $([[ -f $run/SETUP-ERROR ]] && echo written || echo absent), scratch $([[ -d $run/scratch ]] && echo kept || echo removed)"; done
g=$(step 0 0); check "run step: rig exit 0, no node log" 1 "$g" "SETUP-ERROR $([[ -f $T/runs/r00/SETUP-ERROR ]] && echo written || echo absent), scratch $([[ -d $T/runs/r00/scratch ]] && echo kept || echo removed)"
for pat in '> "$run/rig.log" 2>&1 || rc=$?' 'bash ci/rig-setup-check.sh "${rc:-0}" "$run" || { rm -rf "$run/scratch"; exit 1; }'; do
  grep -qF -- "$pat" "$W" && printf '%-36s present  ok\n' "workflow: ${pat:0:30}" || { printf '%-36s MISSING\n' "workflow: ${pat:0:30}"; fail=1; }; done
# the pool step as the workflow has it
python3 - "$W" > "$T/pool.sh" <<'PY'
import sys, yaml
w = yaml.safe_load(open(sys.argv[1]))
print(next(s["run"] for s in w["jobs"]["pool"]["steps"] if s.get("name", "").startswith("Pooled")))
PY
mkdir -p "$T/p/art/fix-d0-1/out" "$T/p/art/base-d0-2"
# a run that ran: its messages decoded from the golden capture (no input blocks, so matrix_prop.py reports zeros)
python3 - "$T/p/art/fix-d0-1/out/messages.jsonl" <<'PY'
import json, sys
sys.path.insert(0, "diag")
import wire
m = json.load(open("tests/fixtures/wire-bringup.json"))
recs, _ = wire.decode_pcap("tests/fixtures/wire-bringup.pcap", "A-B", bytes(m["magic"]), m["names"])
open(sys.argv[1], "w").write("".join(json.dumps(r) + "\n" for r in recs))
PY
cp "$T/runs/r21/SETUP-ERROR" "$T/p/art/base-d0-2/"
pool(){ ( cd "$T/p" && ln -sfn "$ROOT/diag" diag && GITHUB_STEP_SUMMARY=/dev/null bash -eo pipefail pool.sh > out.txt 2>&1 ); echo $?; }
cp "$T/pool.sh" "$T/p/pool.sh"
g=$(pool); check "pool: one setup-error run" 1 "$g" "$(grep -c '^SETUP ERROR' "$T/p/pooled.txt") SETUP ERROR line"
rm "$T/p/art/base-d0-2/SETUP-ERROR"; rmdir "$T/p/art/base-d0-2"
g=$(pool); check "pool: no setup-error run" 0 "$g" "$(grep -c '^SETUP ERROR' "$T/p/pooled.txt") SETUP ERROR line"
[[ $fail == 0 ]] && echo "matrix-relay setup check: all ok" || { echo "matrix-relay setup check: MISMATCH"; exit 1; }
