#!/usr/bin/env bash
# logab-runs.sh: the A/B of the logs. A pull request's A/B shows that the fault is there without the change and gone
# with it; this shows what ELSE changed between the two arms, from the node logs: which per-run log features separate
# the candidate runs from the base runs (diag/features.py) and what the candidate runs log that no base run did
# (diag/sweep.py --baseline). It changes no verdict; it names candidates to read, and a review states its result
# (GUIDE.md, "Logs:"). diffrun/run.sh does this itself after every verdict (diffrun/logab.sh); this script is for runs
# made elsewhere: the rig (PEERYARD_KEEP_LOGS=1 keeps every run's node logs under <out>/logs_<example>/), and
# ergo's integration suite on a CI fork (fork-ci.yml uploads it-logs-<run> artifacts).
#
#   bash review/logab-runs.sh --out DIR --base DIR... --candidate DIR...              # run dirs holding node logs
#   bash review/logab-runs.sh --out DIR --repo OWNER/NAME --spec SpecName --base-runs ID,ID.. --candidate-runs ID,ID..
#
# The second form downloads each run's it-logs artifact (gh), keeps only <SpecName>-*.log, orders a run's containers
# by their first timestamp and names them node_1.., and strips the container timestamp prefix so the node's own line
# start is read. Output: <DIR>/logab_labels.tsv, <DIR>/logab_features.txt, <DIR>/logab_novelty.txt, and a one-line
# summary on stdout. DIFFRUN_LOG_SOURCE=<node source checkout> names the code line behind each message.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; DIAG="$HERE/../diag"
out=""; repo=""; spec=""; base=(); cand=(); brun=""; crun=""
while [[ $# -gt 0 ]]; do case "$1" in
  --out) out="$2"; shift 2 ;; --repo) repo="$2"; shift 2 ;; --spec) spec="$2"; shift 2 ;;
  --base-runs) brun="$2"; shift 2 ;; --candidate-runs) crun="$2"; shift 2 ;;
  --base) shift; while [[ $# -gt 0 && "$1" != --* ]]; do base+=("$1"); shift; done ;;
  --candidate) shift; while [[ $# -gt 0 && "$1" != --* ]]; do cand+=("$1"); shift; done ;;
  *) echo "logab-runs: unknown argument $1" >&2; exit 2 ;; esac; done
[[ -n "$out" ]] || { sed -n '2,17p' "$0" >&2; exit 2; }
mkdir -p "$out"; out="$(cd "$out" && pwd)"
if [[ -n "$repo" ]]; then
  [[ -n "$spec" && -n "$brun" && -n "$crun" ]] || { echo "logab-runs: --repo needs --spec, --base-runs and --candidate-runs" >&2; exit 2; }
  command -v gh >/dev/null || { echo "logab-runs: gh not found" >&2; exit 2; }
  fetch(){ local role="$1" ids="$2" id d; for id in ${ids//,/ }; do d="$out/runs/$role-$id"
      if [[ ! -d "$d" ]]; then mkdir -p "$out/dl/$id"; gh run download "$id" -R "$repo" -D "$out/dl/$id" >/dev/null 2>&1 || { echo "logab-runs: no artifact for run $id" >&2; continue; }
        python3 - "$out/dl/$id" "$d" "$spec" <<'EOF'
import sys, os, glob
src, dst, spec = sys.argv[1:4]
logs = glob.glob(f"{src}/**/{spec}-*.log", recursive=True)
def first_ts(p):
    with open(p, errors="ignore") as f:
        for line in f:
            if line[:4].isdigit(): return line[:30]
    return "z"
logs.sort(key=first_ts)
if logs: os.makedirs(dst, exist_ok=True)
for i, p in enumerate(logs, 1):
    with open(p, errors="ignore") as fi, open(f"{dst}/node_{i}.log", "w") as fo:
        for line in fi:
            fo.write(line.split(" ", 1)[1] if line[:4].isdigit() and "T" in line[:20] and " " in line else line)
print(f"{os.path.basename(dst)}: {len(logs)} node log(s)")
EOF
      fi
      [[ -d "$d" ]] && { [[ $role == base ]] && base+=("$d") || cand+=("$d"); }
    done; }
  fetch base "$brun"; fetch candidate "$crun"
fi
[[ ${#base[@]} -gt 0 && ${#cand[@]} -gt 0 ]] || { echo "logab-runs: need at least one base and one candidate run directory with node logs" >&2; exit 2; }
labels="$out/logab_labels.tsv"; : > "$labels"
for d in "${base[@]}"; do printf '%s\tbase\n' "$(realpath "$d")" >> "$labels"; done
for d in "${cand[@]}"; do printf '%s\tcandidate\n' "$(realpath "$d")" >> "$labels"; done
src=(); [[ -n "${DIFFRUN_LOG_SOURCE:-}" ]] && src=(--source "$DIFFRUN_LOG_SOURCE")
python3 "$DIAG/features.py" --labels "$labels" --target candidate --top 15 "${src[@]}" > "$out/logab_features.txt" 2>&1
python3 "$DIAG/sweep.py" "${cand[@]}" --baseline "${base[@]}" --top 30 "${src[@]}" > "$out/logab_novelty.txt" 2>&1
sep="$(grep -c ' YES ' "$out/logab_features.txt" 2>/dev/null || echo 0)"
echo "logab-runs: ${#base[@]} base / ${#cand[@]} candidate runs; $sep feature(s) separate the arms fully; $(head -1 "$out/logab_novelty.txt" | cut -c1-100); see $out/logab_features.txt, $out/logab_novelty.txt"
