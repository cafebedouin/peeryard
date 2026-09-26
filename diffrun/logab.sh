#!/usr/bin/env bash
# logab.sh <diffrun out dir>: compare the node logs of a scenario's base runs with its candidate runs.
#   logab_features.txt  which per-run log features separate the candidate runs from the base runs (diag/features.py)
#   logab_novelty.txt   what the candidate runs log that no base run did (diag/sweep.py --baseline)
# run.sh calls it after writing the verdict (DIFFRUN_LOGAB=0 skips it). Nothing here changes the verdict: the verdict
# rests on the scenario's metrics; this lists what else differs between the two jars, as candidates to read. On an
# A/A run (the same jar in both roles) it shows how much two identical arms differ by chance.
# DIFFRUN_LOG_SOURCE=<node source checkout>: name the code line behind each message (diag/logmap.py).
set -uo pipefail
OUT="$(realpath -e "${1:?usage: logab.sh <diffrun out dir>}")"; HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIAG="$HERE/../diag"; command -v python3 >/dev/null || { echo "logab: python3 not found; skipped" >&2; exit 0; }
labels="$OUT/logab_labels.tsv"; : > "$labels"; nb=0; nc=0
for d in "$OUT"/runs/*/; do
  d="${d%/}"; role="$(basename "$d")"; role="${role%%-*}"
  [[ $role == base || $role == candidate ]] || continue
  find "$d" \( -name 'node_*.log' -o -name 'node_*.log.gz' \) -print -quit | grep -q . || continue
  printf '%s\t%s\n' "$d" "$role" >> "$labels"; [[ $role == base ]] && nb=$((nb+1)) || nc=$((nc+1))
done
if [[ $nb -eq 0 || $nc -eq 0 ]]; then echo "logab: node logs for $nb base and $nc candidate runs; nothing to compare" >&2; exit 0; fi
src=(); [[ -n "${DIFFRUN_LOG_SOURCE:-}" ]] && src=(--source "$DIFFRUN_LOG_SOURCE")
python3 "$DIAG/features.py" --labels "$labels" --target candidate --top 15 "${src[@]}" > "$OUT/logab_features.txt" 2>&1
mapfile -t cand < <(awk -F'\t' '$2=="candidate"{print $1}' "$labels"); mapfile -t base < <(awk -F'\t' '$2=="base"{print $1}' "$labels")
python3 "$DIAG/sweep.py" "${cand[@]}" --baseline "${base[@]}" --top 30 "${src[@]}" > "$OUT/logab_novelty.txt" 2>&1
echo "logab: $nb base / $nc candidate runs; $(head -1 "$OUT/logab_novelty.txt" | cut -c1-120); see logab_features.txt, logab_novelty.txt" >&2
