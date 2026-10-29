#!/usr/bin/env bash
# browser/compare_selftest.sh: shows compare.py can find what it reports zero of. Plants one verdict flip with a
# RangeError, one console error and one page crash in a scratch copy of the V2 browser results, and one wasm trap
# string in V1; re-runs compare.py on them. Passes when compare.py exits 1 and reports every planted item.
# usage: compare_selftest.sh <node results dir> <browser results dir> <scratch dir>
set -euo pipefail
N="$1"; B="$2"; T="$3"; HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mkdir -p "$T"; cp "$B"/results-browser-V0.json "$T"/
python3 -I - "$B" "$T" <<'PYEOF'
import json, sys
B, T = sys.argv[1], sys.argv[2]
v2 = json.load(open(f"{B}/results-browser-V2.json"))
r = v2["results"][5]
r["inputs"][0]["b"] = {"pass": False, "err": "RangeError: Maximum call stack size exceeded", "range_error": True}
v2["results"][6]["browser"]["console"].append({"type": "error", "text": "planted console error"})
v2["results"][7]["browser"]["crashed"] = True
json.dump(v2, open(f"{T}/results-browser-V2.json", "w"))
v1 = json.load(open(f"{B}/results-browser-V1.json"))
v1["results"][3]["c"] = {"pass": False, "err": "RuntimeError: unreachable"}
json.dump(v1, open(f"{T}/results-browser-V1.json", "w"))
print("planted: V2 tx5 in0.b RangeError (verdict flip + err diff + stack hit); V2 tx6 console error; V2 tx7 crashed;"
      " V1 tx3 c -> RuntimeError: unreachable (verdict flip + err diff + trap hit)")
PYEOF
set +e
out="$(python3 -I "$HERE/compare.py" "$N" "$T")"; rc=$?
set -e
sed -n '/== verdict diff/,/== stack-depth/p' <<< "$out"
sed -n '/== checks/,$p' <<< "$out" | grep -v '^ok '
miss=0
expect() { if grep -Eq -- "$1" <<< "$out"; then echo "found:   $2"; else echo "MISSING: $2"; miss=1; fi; }
expect 'VERDICT DIFF .* in0\.b: browser=\(False'          "V2 tx5 verdict flip"
expect 'in0\.b\.range_error'                              "V2 tx5 RangeError flag"
expect 'console\.error: planted console error'            "V2 tx6 console error"
expect 'page crashed'                                     "V2 tx7 page crash"
expect 'VERDICT DIFF .* c: browser=\(False'               "V1 tx3 verdict flip"
expect 'c\.err~stack/trap: RuntimeError: unreachable'     "V1 tx3 wasm trap"
expect '^FAIL V2 browser verdicts = node verdicts'        "V2 verdict check fails"
expect '^FAIL V1 browser verdicts = node verdicts'        "V1 verdict check fails"
expect '^FAIL V2 no stack error'                          "V2 stack/crash/console check fails"
expect '^FAIL V1 no stack error'                          "V1 trap check fails"
echo "compare.py exit on planted results: $rc (expected 1)"
[[ $rc -eq 1 && $miss -eq 0 ]] && echo "selftest: pass" || { echo "selftest: FAIL"; exit 1; }
