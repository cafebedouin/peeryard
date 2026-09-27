#!/usr/bin/env bash
# with-lock.sh: run one command under the host's single node-network lock, first come first served.
#
#   bash review/with-lock.sh [--wait <seconds>] -- <command> [args...]
#
# The rig, diffrun and every scenario assume one node network at a time on a host (ports, namespaces, CPU
# timing), and an sbt compile disturbs a timing-sensitive node run, so sbt runs queue here too. Several review
# agents on one machine therefore queue for their executed parts and read in parallel. Fairness: each waiter
# drops a ticket in $PEERYARD_LOCK.d/ and only the oldest live ticket may take the file lock. flock alone is not
# FIFO: whichever waiter happens to poll first after a release wins, so an early arrival can wait behind any number
# of later ones. Tickets of dead processes are removed.
# The lock file holds the current holder's line for the waiters' message. Waiting is reported once a minute on
# stderr; --wait caps it (default 6 h). Exit status is the command's; 75 means the wait expired.
set -uo pipefail
LOCK="${PEERYARD_LOCK:-/tmp/peeryard.lock}"; WAIT=$((6 * 3600)); Q="$LOCK.d"
while [[ $# -gt 0 ]]; do case "$1" in
  --wait) WAIT="$2"; shift 2 ;;
  --) shift; break ;;
  *) echo "usage: $0 [--wait <seconds>] -- <command> [args...]" >&2; exit 2 ;; esac; done
[[ $# -gt 0 ]] || { echo "with-lock: no command" >&2; exit 2; }
mkdir -p "$Q" || { echo "with-lock: cannot create $Q" >&2; exit 2; }
TICKET="$Q/$(date +%s%N)-$$"; : > "$TICKET" || exit 2
trap 'rm -f "$TICKET"' EXIT
exec 9>>"$LOCK" || { echo "with-lock: cannot open $LOCK" >&2; exit 2; }   # append: opening must not wipe the holder's line
oldest_live(){ local t p; for t in $(ls "$Q" 2>/dev/null | sort -n); do p="${t##*-}"; if kill -0 "$p" 2>/dev/null; then echo "$t"; return; else rm -f "$Q/$t"; fi; done; }
start=$SECONDS; n=0
until [[ "$(oldest_live)" == "$(basename "$TICKET")" ]] && flock -n 9; do
  n=$((n + 1)); (( n % 6 == 1 )) && echo "with-lock: waiting for $LOCK ($(( (SECONDS - start) / 60 )) min; queue $(ls "$Q" 2>/dev/null | wc -l); held by: $(head -c 120 "$LOCK" 2>/dev/null))" >&2
  (( SECONDS - start >= WAIT )) && { echo "with-lock: gave up after $WAIT s" >&2; exit 75; }
  sleep 10
done
rm -f "$TICKET"   # holder no longer queues; the flock is what it holds
truncate -s 0 "$LOCK"; printf '%s pid %s: %s (%s args)\n' "$(date -u +%FT%TZ)" "$$" "$(basename "${1:-?}")" "$(($# - 1))" >&9   # the command's name only: arguments can carry paths
"$@"; rc=$?; truncate -s 0 "$LOCK"; exit $rc   # the holder line is cleared on release
