#!/usr/bin/env bash
# recount.sh — recount ForkResolutionSpec / DeepRollBackSpec / UtxoStateNodesSyncSpec outcomes in upstream
# ergoplatform/ergo "Run it node tests" jobs, from the job logs themselves.
#
# Claim it checks: the per-pool failure counts of the three tests ("Fork resolution after isolated mining",
# "Deep rollback handling", "Utxo state nodes synchronisation (5 blocks)") in the jobs listed in JOBS_FILE.
# Counts against it: any count this script prints that differs from the table it accompanies.
# Needs: bash, gh (authenticated; public logs), grep, sed, awk. Touches nothing but stdout. ~2-5 s per job.
# Upstream keeps job logs for 90 days; after that the jobs print "log unavailable".
#
# usage: recount.sh JOBS_FILE        (lines: <job_id> <pool label>; '#' comments ignored)
# output: one line per job: job pool tested_base FR DRB USS, then per-pool totals; last line "RECOUNT done".
set -euo pipefail
jobs_file=${1:?usage: recount.sh JOBS_FILE}
declare -A n fr drb uss
while read -r job pool _; do
  [[ -z "${job:-}" || "$job" == \#* ]] && continue
  log=$(gh api "repos/ergoplatform/ergo/actions/jobs/$job/logs" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' | grep -v '\[debug\]' || true)
  if [[ -z "$log" ]]; then echo "$job $pool log unavailable"; continue; fi
  base=$(grep -m1 -oE 'Merge [0-9a-f]{40} into [0-9a-f]{40}' <<<"$log" | awk '{print substr($4,1,9)}' || true)
  out() { # test name -> FAIL / pass / absent
    if grep -qF -- "- $1 *** FAILED ***" <<<"$log" || grep -qF -- "- should $1 *** FAILED ***" <<<"$log"; then echo FAIL
    elif grep -qE -- "\[info\] - (should )?$(sed 's/[()]/\\&/g' <<<"$1")\s*$" <<<"$log"; then echo pass
    else echo absent; fi
  }
  a=$(out "Fork resolution after isolated mining"); b=$(out "Deep rollback handling")
  c=$(out "Utxo state nodes synchronisation (5 blocks)")
  echo "$job $pool ${base:-?} FR=$a DRB=$b USS=$c"
  n[$pool]=$(( ${n[$pool]:-0} + 1 ))
  [[ $a == FAIL ]] && fr[$pool]=$(( ${fr[$pool]:-0} + 1 ))
  [[ $b == FAIL ]] && drb[$pool]=$(( ${drb[$pool]:-0} + 1 ))
  [[ $c == FAIL ]] && uss[$pool]=$(( ${uss[$pool]:-0} + 1 ))
done < "$jobs_file"
for p in "${!n[@]}"; do
  echo "TOTAL $p jobs=${n[$p]} FR=${fr[$p]:-0}/${n[$p]} DRB=${drb[$p]:-0}/${n[$p]} USS=${uss[$p]:-0}/${n[$p]}"
done | sort
echo "RECOUNT done"
