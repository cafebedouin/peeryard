#!/usr/bin/env bash
# crash-verdict.sh: the outcome classifier of the crash-consistency oracle (rig/CRASH-CONSISTENCY.md). It reads one
# observation file written by rig/examples/crash-consistency.sh and prints one verdict line:
#
#   bash rig/crash-verdict.sh <obs.json>
#
#   CRASH-CONSISTENCY SAME@<h>:<best full block id> root=<state root> kills=<n> in_window=<m>
#   CRASH-CONSISTENCY DIFF@<h> <what differs> (sample <i>)
#   CRASH-CONSISTENCY LOGERR@<h> <n> unrecoverable log line(s), first: <line>
#   CRASH-CONSISTENCY STUCK@<subject full>/<subject headers> <ref>=<full> ...
#   CRASH-CONSISTENCY REFUSED <detail>
#   CRASH-CONSISTENCY INCONCLUSIVE <reason>
#
# Exit 0 SAME, 1 DIFF / LOGERR / STUCK / REFUSED, 3 INCONCLUSIVE, 2 usage or unreadable input.
#
# The observation (written by the hook; tests/fixtures/crash-consistency/ has examples):
#   { "subject": "S", "refs": ["R", "M"],
#     "staging": { "control": "none|aa|no-restart|behind|fork", "kills_planned": K, "kills_done": n,
#                  "kills_in_window": m, "min_in_window": j, "harness_fail": [..] },
#     "kills": [ {...per kill, reported only...} ],
#     "samples": [ { "t": <ms>, "nodes": { "<name>": { "answered": bool, "full": h, "headers": h, "bestFull": id,
#                    "bestHeader": id, "root": hex } }, "subject_at": { "<ref>": <ref's header id at the subject's
#                    full height, or null> } } ],
#     "log_fatal": [ "<line>", ... ],
#     "indexer": null | { "line": "INDEXER-DIFF ..." } }
#
# Rules, first match wins:
#   1. INCONCLUSIVE when the staging did not happen: a harness failure, fewer kills done than planned, fewer kills
#      inside the apply window than min_in_window, or no sample at all.
#   2. REFUSED when the subject does not answer REST in the last sample (the detail says whether it ever answered).
#   3. DIFF@h when any sample shows the subject and a reference at an equal full height with a different best full
#      block id or a different state root, or the subject's best full block id differs from a reference's header id
#      at the subject's full height (the subject sits on a block the reference's chain does not hold).
#   4. In the last sample, the subject and every reference at one full height with one best full block id and one
#      state root: SAME@h, or LOGERR@h when the subject's log holds an unrecoverable line (log_fatal non-empty).
#      With an indexer line: its DIFF makes the outcome DIFF@indexer, its INCONCLUSIVE makes the run INCONCLUSIVE.
#   5. INCONCLUSIVE when the references do not agree with each other in the last sample (the settle did not hold).
#   6. Otherwise STUCK@<full>/<headers>: the subject answers, holds no conflicting block, and does not agree.
# The samples a hook passes are taken after its settle rule (the miner paused), so every one of them is judged.
set -uo pipefail
[[ $# -eq 1 ]] || { echo "usage: $0 <obs.json>" >&2; exit 2; }
jq -e 'type == "object" and (.samples | type == "array")' "$1" >/dev/null 2>&1 \
  || { echo "CRASH-CONSISTENCY INCONCLUSIVE unreadable observation $1"; exit 2; }
line="$(jq -r '
  . as $o | ($o.subject // "S") as $s | ($o.refs // ["R", "M"]) as $refs | ($o.staging // {}) as $st |
  def short: if type == "string" and length > 16 then .[0:16] else . end;
  def agree($a; $b): $a.answered and $b.answered and ($a.full // 0) >= 1 and $a.full == $b.full
                     and $a.bestFull == $b.bestFull and $a.root == $b.root and $a.bestFull != null and $a.root != null;
  # the first difference in one sample, or null
  def sample_diff($i):
    . as $x | $x.nodes[$s] as $sn |
    first( $refs[] as $r | $x.nodes[$r] as $rn |
      if ($sn.answered and $rn.answered and ($sn.full // 0) >= 1 and $sn.full == $rn.full
          and $sn.bestFull != null and $rn.bestFull != null and $sn.bestFull != $rn.bestFull)
        then "DIFF@\($sn.full) best full block \($s)=\($sn.bestFull | short) \($r)=\($rn.bestFull | short) (sample \($i))"
      elif ($sn.answered and $rn.answered and ($sn.full // 0) >= 1 and $sn.full == $rn.full
          and $sn.root != null and $rn.root != null and $sn.root != $rn.root)
        then "DIFF@\($sn.full) state root \($s)=\($sn.root | short) \($r)=\($rn.root | short) (sample \($i))"
      elif ($sn.answered and ($sn.full // 0) >= 1 and $sn.bestFull != null and (($x.subject_at // {})[$r] // null) != null
          and $x.subject_at[$r] != $sn.bestFull)
        then "DIFF@\($sn.full) off-chain: \($s) best full block \($sn.bestFull | short), \($r) header at that height \($x.subject_at[$r] | short) (sample \($i))"
      else empty end ) // null;
  ($st.harness_fail // []) as $hf |
  if ($hf | length) > 0 then "INCONCLUSIVE harness: \($hf | join("; "))"
  elif ($st.kills_done // 0) < ($st.kills_planned // 0) then "INCONCLUSIVE staging: \($st.kills_done // 0) of \($st.kills_planned) kills done"
  elif ($st.kills_in_window // 0) < ($st.min_in_window // 0) then "INCONCLUSIVE staging: \($st.kills_in_window // 0) kill(s) inside the apply window, \($st.min_in_window) required"
  elif ($o.samples | length) == 0 then "INCONCLUSIVE no sample taken"
  else
    ($o.samples | last) as $last |
    if ($last.nodes[$s].answered | not) then
      "REFUSED \($s) does not answer REST at the end (\(if any($o.samples[]; .nodes[$s].answered) then "it answered in an earlier sample" else "never answered after the last restart" end))"
    else
      ([ $o.samples | to_entries[] | .key as $i | .value | sample_diff($i) | select(. != null) ] | first) as $d |
      if $d != null then $d
      elif all($refs[]; agree($last.nodes[$s]; $last.nodes[.])) then
        ($last.nodes[$s]) as $sn |
        (($o.indexer // {}).line // "") as $il |
        if ($il | test(" DIFF@")) then "DIFF@indexer \($il | sub("^INDEXER-DIFF [^ ]+ DIFF@"; ""))"
        elif ($il | test(" INCONCLUSIVE")) then "INCONCLUSIVE indexer: \($il | sub("^INDEXER-DIFF [^ ]+ INCONCLUSIVE "; ""))"
        elif (($o.log_fatal // []) | length) > 0 then
          "LOGERR@\($sn.full) \($o.log_fatal | length) unrecoverable log line(s), first: \($o.log_fatal[0] | .[0:160])"
        else "SAME@\($sn.full):\($sn.bestFull) root=\($sn.root | short) kills=\($st.kills_done // 0) in_window=\($st.kills_in_window // 0)\(if $il != "" then " indexer=SAME" else "" end)"
        end
      elif any($refs[]; . as $r | ($refs | map(agree($last.nodes[$r]; $last.nodes[.])) | all) | not) then
        "INCONCLUSIVE references disagree at the end (\([ $refs[] as $r | "\($r)=\($last.nodes[$r].full // "?"):\($last.nodes[$r].bestFull // "?" | short)" ] | join(" "))): the settle did not hold"
      else
        ($last.nodes[$s]) as $sn |
        "STUCK@\($sn.full // 0)/\($sn.headers // 0) \([ $refs[] as $r | "\($r)=\($last.nodes[$r].full // "?")" ] | join(" "))"
      end
    end
  end' "$1")" || { echo "CRASH-CONSISTENCY INCONCLUSIVE classifier error"; exit 3; }
echo "CRASH-CONSISTENCY $line"
case "$line" in SAME@*) exit 0 ;; INCONCLUSIVE*) exit 3 ;; *) exit 1 ;; esac
