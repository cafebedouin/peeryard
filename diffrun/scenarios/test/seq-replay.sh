#!/usr/bin/env bash
# Test scenario for the sequential rule (no nodes): replays the jar file's T/F pattern, one character per call,
# counting calls in <jar>.count. Driven by tests/sequential.sh (and, under a stub precheck, tests/precheck.sh, which
# sets SCEN_NAME through the manifest env so the result names that manifest).
pat="$(cat "$1")"; c=$(( $(cat "$1.count" 2>/dev/null || echo 0) + 1 )); echo $c > "$1.count"
# <jar>.cause names a cause code: the run ends INCONCLUSIVE the way a scenario's die does (tests/precheck.sh, case 6)
if [[ -f "$1.cause" ]]; then echo "CAUSE $(cat "$1.cause")"; echo "[stub] INCONCLUSIVE: stub asked to fail with a cause"; exit 3; fi
ch="${pat:$((c-1)):1}"; sw=false; [[ $ch == T ]] && sw=true
echo "RESULT_JSON $(jq -cn --argjson s $sw --arg n "${SCEN_NAME:-seq-replay}" '{schema_version:1,scenario:$n,versions:{A:"1"},metrics:{switched:$s}}')"
