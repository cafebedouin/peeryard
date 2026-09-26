#!/usr/bin/env bash
# run-captured.sh <capture-file> -- <command> [args...]: run a hand-written executed command with its provenance
# recorded at the top of the capture (command line, cwd, git revision of the cwd if any, JDK, time), then its
# combined output. A report claim about the run cites the capture; the header is what a reviewer needs to repeat it.
set -uo pipefail
CAP="${1:-}"; shift || true; [[ "${1:-}" == "--" ]] && shift
[[ -n "$CAP" && $# -gt 0 ]] || { echo "usage: $0 <capture-file> -- <command> [args...]" >&2; exit 2; }
mkdir -p "$(dirname "$CAP")"
{ echo "# run-captured $(date -u +%FT%TZ)"; echo "# cwd: $PWD"; echo "# git: $(git rev-parse --short HEAD 2>/dev/null || echo none) $(git status --porcelain 2>/dev/null | wc -l | sed 's/$/ uncommitted/')"
  echo "# java: $(java -version 2>&1 | head -1)  JAVA_HOME=${JAVA_HOME:-}  XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-}"; printf '# cmd:'; printf ' %q' "$@"; echo; echo "# ---"; } > "$CAP"
"$@" 2>&1 | tee -a "$CAP"; rc=${PIPESTATUS[0]}
echo "# exit $rc $(date -u +%FT%TZ)" >> "$CAP"; exit "$rc"
