#!/usr/bin/env bash
# indexer-cmp.sh: compare two extra-indexer snapshots (rig/lib/indexer.sh, idx_snapshot) and print one verdict line.
#
#   bash rig/indexer-cmp.sh [--label L] [--positive-control] [--show K] <x.json> <y.json>
#
# A snapshot is one node's answers to the /blockchain/... routes at one moment, plus a settle record taken before and
# after the queries (full height, best full block id, the indexer's indexedHeight) and the list of requests that did not
# answer 200 or 404. The verdict line is one of:
#   INDEXER-DIFF <L> SAME@<h>:<best full block id> fields=<n>
#   INDEXER-DIFF <L> DIFF@<field> x=<value> y=<value> (<k> of <n> fields differ)
#   INDEXER-DIFF <L> INCONCLUSIVE <reason>
# followed, for a DIFF, by up to K (default 8) lines `  diff <field> x=<value> y=<value>`. Exit 0 SAME, 1 DIFF,
# 3 INCONCLUSIVE, 2 usage or unreadable input.
#
# Settle rule (INCONCLUSIVE when any part fails): in each snapshot the settle record is the same before and after the
# queries (no block arrived and the indexer did not move while the node was being read), the indexer's indexedHeight
# equals the node's full height, and every request answered 200 or 404 (a 503 from a recovering indexer, a timeout or
# a 5xx is not an answer to compare); and both snapshots are at the same best full block id. --positive-control drops
# only the last condition (the two snapshots may be at different blocks): it exists to show that the comparator reports
# a DIFF when the answers really differ, e.g. one node read before a payment confirmed and the other after.
#
# What is compared: everything in the snapshot except `meta` (node name, version), `settle` and `errors`. Values are
# flattened to leaf paths (an empty array or object is a leaf of its own), so a field present on one side only is a
# difference with `<absent>` on the other side. The first differing path in sorted order is named in the verdict.
set -uo pipefail
label=compare; posctl=false; show=8
while [[ $# -gt 0 ]]; do case "$1" in
  --label) label="$2"; shift 2 ;;
  --positive-control) posctl=true; shift ;;
  --show) show="$2"; shift 2 ;;
  --) shift; break ;;
  -*) echo "usage: $0 [--label L] [--positive-control] [--show K] <x.json> <y.json>" >&2; exit 2 ;;
  *) break ;; esac; done
[[ $# -eq 2 ]] || { echo "usage: $0 [--label L] [--positive-control] [--show K] <x.json> <y.json>" >&2; exit 2; }
for f in "$1" "$2"; do jq -e 'type == "object"' "$f" >/dev/null 2>&1 || { echo "INDEXER-DIFF $label INCONCLUSIVE unreadable snapshot $f"; exit 3; }; done
[[ "$show" =~ ^[0-9]+$ ]] || { echo "--show: a number" >&2; exit 2; }

out="$(jq -n -r --slurpfile x "$1" --slurpfile y "$2" --arg label "$label" --argjson posctl "$posctl" --argjson show "$show" '
  $x[0] as $x | $y[0] as $y |
  def short: tojson | if length > 200 then .[0:197] + "..." else . end;
  # the settle problems of one snapshot, as strings
  def unsettled($n):
    (.settle // {}) as $s |
    [ (if ($s.before == null or $s.after == null) then "\($n): no settle record" else empty end),
      (if ($s.before != null and $s.after != null and $s.before != $s.after)
         then "\($n): moved during the read (before \($s.before | tojson), after \($s.after | tojson))" else empty end),
      (if ($s.after != null and $s.after.indexedHeight != $s.after.fullHeight)
         then "\($n): indexedHeight \($s.after.indexedHeight) != fullHeight \($s.after.fullHeight)" else empty end),
      (if ($s.after != null and (($s.after.fullHeight // 0) < 1)) then "\($n): no full block" else empty end),
      (if ((.errors // []) | length) > 0
         then "\($n): \(.errors | length) request(s) not answered 200/404, first \(.errors[0] | tojson)" else empty end) ];
  # flatten to {path: value}; an empty container is a leaf
  def flat:
    [ paths(type != "object" and type != "array" or length == 0) as $p
      | { key: ($p | map(if type == "number" then "[\(.)]" else ".\(.)" end) | join("")), value: getpath($p) } ]
    | from_entries;
  (($x | unsettled("x")) + ($y | unsettled("y"))) as $bad |
  if ($bad | length) > 0 then "INDEXER-DIFF \($label) INCONCLUSIVE not settled: \($bad | join("; "))"
  elif ($posctl | not) and ($x.settle.after.bestFullHeaderId != $y.settle.after.bestFullHeaderId)
    then "INDEXER-DIFF \($label) INCONCLUSIVE not settled: different best full blocks (x \($x.settle.after.fullHeight):\($x.settle.after.bestFullHeaderId), y \($y.settle.after.fullHeight):\($y.settle.after.bestFullHeaderId))"
  else
    ($x | del(.meta, .settle, .errors) | flat) as $fx |
    ($y | del(.meta, .settle, .errors) | flat) as $fy |
    ([$fx, $fy] | map(keys) | add | unique) as $keys |
    [ $keys[] | . as $k | select(($fx | has($k)) != ($fy | has($k)) or $fx[$k] != $fy[$k]) ] as $d |
    def val($m; $k): if ($m | has($k)) then ($m[$k] | short) else "<absent>" end;
    if ($d | length) == 0 then
      "INDEXER-DIFF \($label) SAME@\($x.settle.after.fullHeight):\($x.settle.after.bestFullHeaderId) fields=\($keys | length)"
    else
      ( "INDEXER-DIFF \($label) DIFF@\($d[0]) x=\(val($fx; $d[0])) y=\(val($fy; $d[0])) (\($d | length) of \($keys | length) fields differ)",
        ($d[0:$show][] | . as $k | "  diff \($k) x=\(val($fx; $k)) y=\(val($fy; $k))") )
    end
  end')" || { echo "INDEXER-DIFF $label INCONCLUSIVE comparator error"; exit 3; }
echo "$out"
case "$(head -1 <<< "$out" | cut -d' ' -f3)" in
  SAME@*) exit 0 ;; DIFF@*) exit 1 ;; *) exit 3 ;; esac
