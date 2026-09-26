#!/usr/bin/env bash
# output-lint-stub.sh: a test scenario that launches no nodes. It prints a valid RESULT_JSON whose version
# string carries a term from the runner's output lint list. The term is assembled at runtime, so this file
# itself passes the input lint; with DIFFRUN_TERMS listing that term, the runner must refuse to write its verdict.
set -euo pipefail
[[ -f "${1:?usage: $0 <jar>}" ]] || { echo "no jar: $1" >&2; exit 2; }
v="0.0.1-$(printf '%s%s' 'shibb' 'oleth')"
echo "RESULT_JSON $(jq -cn --arg v "$v" '{schema_version:1,scenario:"output-lint-stub",versions:{A:$v},metrics:{ok:true}}')"
