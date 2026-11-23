#!/usr/bin/env bash
# Closing an LDBVersionedStore while processSnapshot is still using its snapshot.
#
# CloseMidSnapshot.java runs once per (jar, JDK, case), each in its own JVM, with the node jar on the class path, so the
# store opens its LevelDB through the node's own factory (native leveldbjni, as `java -jar` loads it). Latches, not
# timing, force the order: the processing reads once, a second thread calls store.close(), then (C1) the processing
# reads again or (C2) just returns, and processSnapshot releases its snapshot; C3 starts a second processSnapshot once
# close() has started and lets the first one finish; C0 is the control (no close during the processing).
#
# Usage: bash run.sh <label>=<node jar> [<label>=<node jar> ...]
#   e.g. bash run.sh v6.0.11=ergo-6.0.11.jar fixed=ergo-fixed.jar
# Per run it prints the CASE line, the exit code and, if the JVM crashed, only the crash summary (signal line,
# problematic frame, Java frames) from the JVM's error file; the error file itself is deleted with the work directory.
# A hang is reported by the harness itself (exit 3) after 10 s; every JVM is also capped at 60 s (exit 124).
#
# Needs: bash, JDK 8 (javac and java) and optionally JDK 21, as JDK8_HOME / JDK21_HOME (default /usr/lib/jvm/
# java-<v>-openjdk-amd64); x86_64 Linux (leveldbjni's bundled library).
# Touches: only a new temporary directory, removed at the end (each JVM's java.io.tmpdir, where leveldbjni unpacks its
# native library, is inside it).
# Stop: Ctrl-C at any point; nothing runs in the background.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ $# -gt 0 ]] || { sed -n '2,20p' "$0"; exit 2; }
declare -A J=([8]="${JDK8_HOME:-/usr/lib/jvm/java-8-openjdk-amd64}" [21]="${JDK21_HOME:-/usr/lib/jvm/java-21-openjdk-amd64}")
[[ -x "${J[8]}/bin/javac" ]] || { echo "JDK 8 not found at ${J[8]} (set JDK8_HOME)" >&2; exit 2; }
jdks=(8); [[ -x "${J[21]}/bin/java" ]] && jdks+=(21)
for a in "$@"; do [[ "$a" == *=* && -f "${a#*=}" ]] || { echo "not <label>=<existing jar>: $a" >&2; exit 2; }; done
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
mkdir -p "$work/cls"
"${J[8]}/bin/javac" -cp "${1#*=}" -d "$work/cls" "$here/CloseMidSnapshot.java" || exit 2
for f in CloseMidSnapshot.java run.sh; do echo "$(sha256sum < "$here/$f" | cut -c1-64)  $f"; done
for a in "$@"; do echo "$(sha256sum < "${a#*=}" | cut -c1-64)  ${a%%=*}"; done
for v in "${jdks[@]}"; do echo "JDK $v: $("${J[$v]}/bin/java" -version 2>&1 | head -1)"; done
for a in "$@"; do
  label="${a%%=*}"; jar="${a#*=}"
  for v in "${jdks[@]}"; do
    for c in C0 C1 C2 C3; do
      d="$work/$label-$v-$c"; mkdir -p "$d"
      ( cd "$d" && timeout 60 "${J[$v]}/bin/java" -Djava.io.tmpdir="$d" -XX:ErrorFile="$d/hs_err_%p.log" -cp "$jar:$work/cls" \
          CloseMidSnapshot "$c" "$d/stores" ) > "$d/out.txt" 2>&1; rc=$?
      echo "== $label JDK $v $c: exit $rc"
      grep -E '^(CASE|STEP main: after)' "$d/out.txt" | sed 's/^/   /'
      [[ $rc -ne 0 ]] && ! grep -q '^CASE' "$d/out.txt" && echo "   last step: $(grep '^STEP ' "$d/out.txt" | tail -1 | cut -c6-)"
      hs="$(ls "$d"/hs_err_*.log 2>/dev/null | head -1)"
      if [[ -n "$hs" ]]; then
        echo "   crash: $(grep -m1 '^siginfo:' "$hs")"
        echo "   crash: $(grep -m1 -A1 '^# Problematic frame:' "$hs" | tail -1 | sed 's/^# //')"
        awk '/^Java frames:/{f=1;next} f&&/^$/{exit} f' "$hs" | sed 's/^/   crash java frame: /'
      fi
    done
  done
done
