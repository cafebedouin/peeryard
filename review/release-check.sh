#!/usr/bin/env bash
# release-check.sh: the release-candidate check as one command. Dispatches, on GitHub-hosted runners through
# pr-scenario.yml, the fixed set used for ergoplatform/ergo#2640 (6.0.8 candidate vs v6.0.7): interop (the release
# and the candidate on one network, each mining in turn), the release with itself (A/A for interop), the
# extra-indexer differential, fork-convergence-smoke and sibling-fork, all with base = the previous release tag and
# candidate = that tag + the release PR's production diff. Sizes are fixed here, before any run, so the pooled
# tables are read as dispatched. Writes the run ids to <out>/runs.tsv; `collect` downloads the pooled tables and
# prints one summary table in the form the #2640 report used (review/RELEASE-CHECK.md says how to read it).
#
#   bash review/release-check.sh dispatch --pr N --head <40 hex> --line vX.Y.Z [--out DIR] [--repo owner/name]
#   bash review/release-check.sh collect  [--out DIR] [--repo owner/name]
#
# Cost (measured 2026-10-11 for #2640): 5 builds, ~20 runner jobs, about 6-8 runner-hours. Needs gh (authenticated),
# jq. A scenario that lives on a branch rather than main is dispatched with --ref on that branch (see SETS below).
set -euo pipefail
REPO=cafebedouin/peeryard; OUT=release-check.out; cmd="${1:-}"; shift || true
PR=""; HEAD=""; LINE=""
while [[ $# -gt 0 ]]; do case "$1" in
  --pr) PR="$2"; shift 2;; --head) HEAD="$2"; shift 2;; --line) LINE="$2"; shift 2;;
  --out) OUT="$2"; shift 2;; --repo) REPO="$2"; shift 2;;
  *) echo "release-check: unknown argument $1" >&2; exit 2;; esac; done
# label | scenario | shards | pairs | aa | ref (main unless the scenario is not on main yet)
SETS=$'interop\tinterop\t3\t2\tfalse\tmain
interop-aa\tinterop\t1\t2\ttrue\tmain
indexer-diff\tindexer-diff\t3\t1\tfalse\tindexer-diff
fork-convergence\tfork-convergence-smoke\t5\t2\tfalse\tmain
sibling-fork\tsibling-fork\t4\t1\tfalse\tmain'
mkdir -p "$OUT"
case "$cmd" in
  dispatch)
    [[ "$PR" =~ ^[0-9]+$ && "$HEAD" =~ ^[0-9a-f]{40}$ && "$LINE" =~ ^v[0-9.]+$ ]] || { sed -n '2,16p' "$0" >&2; exit 2; }
    printf 'label\tscenario\tshards\tpairs\taa\tref\trun_id\n' > "$OUT/runs.tsv"
    while IFS=$'\t' read -r label scen shards pairs aa ref; do
      args=(-f "line=$LINE" -f "scenario=$scen" -f "shards=$shards" -f "pairs=$pairs")
      if [ "$aa" = true ]; then args+=(-f aa=true); else args+=(-f "pr=$PR" -f "head=$HEAD"); fi
      # find this dispatch's run by its title (pr-scenario's run-name) and creation time, not by "the newest run":
      # other people's dispatches of the same workflow may land in between
      if [ "$aa" = true ]; then want="$scen: A/A on $LINE (${shards}x${pairs})"; else want="$scen: #$PR on $LINE (${shards}x${pairs})"; fi
      since="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      gh workflow run pr-scenario.yml -R "$REPO" --ref "$ref" "${args[@]}"
      id=""; for _ in $(seq 1 20); do sleep 3
        id="$(gh run list -R "$REPO" -w pr-scenario.yml -L 20 --json databaseId,displayTitle,createdAt 2>/dev/null \
          | jq -r --arg w "$want" --arg t "$since" '[.[] | select(.createdAt >= $t and (.displayTitle | startswith($w)))] | .[-1].databaseId // empty')"
        [ -n "$id" ] && break; done
      [ -n "$id" ] || { echo "release-check: no run appeared for $label" >&2; exit 1; }
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$label" "$scen" "$shards" "$pairs" "$aa" "$ref" "$id" | tee -a "$OUT/runs.tsv"
    done <<< "$SETS"
    echo "release-check: dispatched; when the runs finish: bash $0 collect --out $OUT" ;;
  collect)
    [ -f "$OUT/runs.tsv" ] || { echo "release-check: no $OUT/runs.tsv (dispatch first)" >&2; exit 2; }
    printf '| set | run | verdict | base | candidate |\n|---|---|---|---|---|\n'
    tail -n +2 "$OUT/runs.tsv" | while IFS=$'\t' read -r label scen shards pairs aa ref id; do
      st="$(gh run view "$id" -R "$REPO" --json status,conclusion -q '"\(.status)/\(.conclusion)"')"
      if [[ "$st" != completed/* ]]; then printf '| %s | %s | %s | | |\n' "$label" "$id" "$st"; continue; fi
      d="$OUT/$label"; rm -rf "$d"; gh run download "$id" -R "$REPO" -n pr-scenario-pooled -D "$d" >/dev/null 2>&1 || true
      t="$d/table.txt"; [ -f "$t" ] || { printf '| %s | %s | no pooled table (%s) | | |\n' "$label" "$id" "$st"; continue; }
      verdict="$(head -1 "$t" | sed -E 's/.*verdict: ([A-Z]+).*/\1/')"
      role(){ awk -v r="$1" '$1 == r { printf "valid %s void %s inconcl %s pass %s", $2, $3, $4, $5; exit }' "$t"; }
      printf '| %s | %s | %s | %s | %s |\n' "$label" "$id" "$verdict" "$(role base)" "$(role candidate)"
    done
    echo; echo "Per-run metrics are in $OUT/<set>/table.txt; read them with review/RELEASE-CHECK.md before quoting a verdict." ;;
  *) sed -n '2,16p' "$0" >&2; exit 2 ;;
esac
