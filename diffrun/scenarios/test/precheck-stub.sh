#!/usr/bin/env bash
# precheck-stub.sh: a test precheck that launches no nodes. It reads <jar>.precheck: "pass" exits 0, "hang" sleeps
# past any short precheck timeout, anything else prints an INCONCLUSIVE line and exits 3. Calls are counted in
# <jar>.precheck.count. Driven by tests/precheck.sh.
set -uo pipefail
mode="$(cat "${1:?usage: $0 <jar>}.precheck" 2>/dev/null || echo fail)"
echo $(( $(cat "$1.precheck.count" 2>/dev/null || echo 0) + 1 )) > "$1.precheck.count"
case "$mode" in
  pass) echo "[precheck-stub] pass"; exit 0 ;;
  hang) sleep 60; exit 0 ;;
  *) echo "INCONCLUSIVE: precheck stub says $mode"; exit 3 ;;
esac
