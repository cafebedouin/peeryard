#!/usr/bin/env bash
# release-check.sh: the release-candidate check as one command. Dispatches, on GitHub-hosted runners through
# pr-scenario.yml, the fixed set used for ergoplatform/ergo#2640 (6.0.8 candidate vs v6.0.7): interop (the release
# and the candidate on one network, each mining in turn), the release with itself (A/A for interop), the
# extra-indexer differential, fork-convergence-smoke and sibling-fork, and since then crash-consistency, the wallet
# workload's sequential list (wallet-workload-plain) and the wallet oracle through a restart and a crash
# (wallet-oracle-restart). Base = the line; candidate = the line + a release PR's production diff (--pr), or the
# line + a patch file committed in this repository (--patch: pr-scenario's patch mode, e.g. a composite of several
# PRs' production diffs). Sizes are fixed here, before any run, so the pooled tables are read as dispatched. Writes the
# run ids to <out>/runs.tsv and the candidate to <out>/candidate.txt; `collect` downloads the pooled tables and prints
# one summary table in the form the #2640 report used (review/RELEASE-CHECK.md says how to read it).
#
#   bash review/release-check.sh dispatch --pr N --head <40 hex> --line <vX.Y.Z | 40-hex commit> [options]
#   bash review/release-check.sh dispatch --patch patches/<dir>/<file>.patch --line <vX.Y.Z | 40-hex commit> [options]
#   bash review/release-check.sh collect  [--out DIR] [--repo owner/name]
# options: --only label,label (dispatch those sets only, appended to runs.tsv; pace a set across the job limit)
#          --ref BRANCH (dispatch every set on this ref; a --patch file must be on it, byte for byte)
#          --dry-run (print the dispatches, call nothing)  --out DIR  --repo owner/name
#
# Cost, from the jobs API (completed_at - started_at per job, summed): the eight sets below for ergoplatform/ergo#2719
# (6.0.9 candidate vs v6.0.8, 2026-10-17) took 38 jobs (8 builds, 22 shards, 8 pools) and 231 job-minutes, 256 with
# each job rounded up to the minute: about 4 job-hours. The first five lines alone, for #2640 (2026-10-11), took 26
# jobs and 200 job-minutes. All eight at once put 22 shard jobs in flight (on an account limit below that, dispatch
# them in two --only batches). Needs gh (authenticated), jq, git. A scenario that lives on a branch rather than main is
# dispatched with --ref on that branch (see SETS below).
set -euo pipefail
REPO=cafebedouin/peeryard; OUT=release-check.out; cmd="${1:-}"; shift || true
PR=""; HEAD=""; LINE=""; PATCH=""; ONLY=""; REF=""; DRY=0; POLL="${RELEASE_CHECK_POLL_S:-3}"
usage(){ sed -n '2,19p' "$0" >&2; exit 2; }
die(){ echo "release-check: $*" >&2; exit 2; }
while [[ $# -gt 0 ]]; do case "$1" in
  --pr) PR="$2"; shift 2;; --head) HEAD="$2"; shift 2;; --line) LINE="$2"; shift 2;;
  --patch) PATCH="$2"; shift 2;; --only) ONLY="$2"; shift 2;; --ref) REF="$2"; shift 2;; --dry-run) DRY=1; shift;;
  --out) OUT="$2"; shift 2;; --repo) REPO="$2"; shift 2;;
  *) echo "release-check: unknown argument $1" >&2; exit 2;; esac; done
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# label | scenario | shards | pairs | aa | ref (main unless the scenario is not on main yet)
SETS=$'interop\tinterop\t3\t2\tfalse\tmain
interop-aa\tinterop\t1\t2\ttrue\tmain
indexer-diff\tindexer-diff\t3\t1\tfalse\tmain
fork-convergence\tfork-convergence-smoke\t5\t2\tfalse\tmain
sibling-fork\tsibling-fork\t4\t1\tfalse\tmain
crash-consistency\tcrash-consistency\t2\t1\tfalse\tmain
wallet-workload\twallet-workload-plain\t2\t1\tfalse\tmain
wallet-oracle-restart\twallet-oracle-restart\t2\t1\tfalse\tmain'
case "$cmd" in
  dispatch)
    [[ "$LINE" =~ ^v[0-9.]+$ || "$LINE" =~ ^[0-9a-f]{40}$ ]] || usage
    if [ -n "$PATCH" ]; then
      [ -z "$PR$HEAD" ] || die "--patch replaces --pr/--head (patch mode: the candidate is the line + the patch)"
      # the same rule pr-scenario.yml applies to extra_patch, checked here so a bad path fails before any dispatch
      [[ "$PATCH" =~ ^patches/[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*\.patch$ && "$PATCH" != *..* && "$PATCH" != patches/test/* ]] \
        || die "--patch: one file under patches/, not patches/test/, path relative to the repository root"
      [ -f "$ROOT/$PATCH" ] || die "--patch: no file $PATCH in $ROOT"
      PSHA="$(sha256sum "$ROOT/$PATCH" | cut -d' ' -f1)"
      cand="patch mode: line $LINE + $PATCH (sha256 $PSHA)"; tag="patch + $PATCH"
    else
      [[ "$PR" =~ ^[0-9]+$ && "$HEAD" =~ ^[0-9a-f]{40}$ ]] || usage
      cand="PR mode: line $LINE + #$PR production diff at $HEAD"; tag="#$PR"
    fi
    [ -z "$REF" ] || [[ "$REF" =~ ^[A-Za-z0-9._/-]+$ ]] || die "--ref: a branch name"
    sel="$SETS"
    if [ -n "$ONLY" ]; then
      for l in ${ONLY//,/ }; do cut -f1 <<< "$SETS" | grep -qxF -- "$l" || die "--only: no set '$l' (sets: $(cut -f1 <<< "$SETS" | tr '\n' ' '))"; done
      sel="$(awk -F'\t' -v only=",$ONLY," 'index(only, "," $1 ",")' <<< "$SETS")"
    fi
    if [ "$DRY" = 1 ]; then echo "release-check: dry run, $cand"; else
      mkdir -p "$OUT"
      # one candidate per output directory: --only appends to runs.tsv, so a second candidate there would mix tables
      if [ -n "$ONLY" ] && [ -f "$OUT/candidate.txt" ]; then
        [ "$(head -1 "$OUT/candidate.txt")" = "$cand" ] || die "$OUT holds runs of another candidate ($(head -1 "$OUT/candidate.txt")); use another --out"
      else printf '%s\n' "$cand" > "$OUT/candidate.txt"; printf 'label\tscenario\tshards\tpairs\taa\tref\trun_id\n' > "$OUT/runs.tsv"; fi
      [ -f "$OUT/runs.tsv" ] || printf 'label\tscenario\tshards\tpairs\taa\tref\trun_id\n' > "$OUT/runs.tsv"
    fi
    declare -A checked=()
    while IFS=$'\t' read -r label scen shards pairs aa ref; do
      ref="${REF:-$ref}"
      args=(-f "line=$LINE" -f "scenario=$scen" -f "shards=$shards" -f "pairs=$pairs")
      if [ "$aa" = true ]; then args+=(-f aa=true)
      elif [ -n "$PATCH" ]; then args+=(-f "extra_patch=$PATCH")
      else args+=(-f "pr=$PR" -f "head=$HEAD"); fi
      # find this dispatch's run by its title (pr-scenario's run-name) and creation time, not by "the newest run":
      # other people's dispatches of the same workflow may land in between
      if [ "$aa" = true ]; then want="$scen: A/A on $LINE (${shards}x${pairs})"; else want="$scen: $tag on $LINE (${shards}x${pairs})"; fi
      if [ "$DRY" = 1 ]; then printf '%s\t%s\tgh workflow run pr-scenario.yml -R %s --ref %s %s\n' "$label" "$want" "$REPO" "$ref" "${args[*]}"; continue; fi
      if [ -n "$PATCH" ] && [ -z "${checked[$ref]:-}" ]; then
        # the workflow applies the patch from its own checkout of the ref: the bytes there must be the bytes read here
        remote="$(gh api "repos/$REPO/contents/$PATCH?ref=$ref" --jq .sha 2>/dev/null)" || remote=""
        [ "$remote" = "$(git hash-object "$ROOT/$PATCH")" ] || { echo "release-check: $PATCH on $REPO@$ref is ${remote:-absent}, not this file ($(git hash-object "$ROOT/$PATCH")): push it first" >&2; exit 1; }
        checked[$ref]=1
      fi
      since="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      gh workflow run pr-scenario.yml -R "$REPO" --ref "$ref" "${args[@]}"
      id=""; for _ in $(seq 1 20); do sleep "$POLL"
        id="$(gh run list -R "$REPO" -w pr-scenario.yml -L 20 --json databaseId,displayTitle,createdAt 2>/dev/null \
          | jq -r --arg w "$want" --arg t "$since" '[.[] | select(.createdAt >= $t and (.displayTitle | startswith($w)))] | .[-1].databaseId // empty')"
        [ -n "$id" ] && break; done
      [ -n "$id" ] || { echo "release-check: no run appeared for $label" >&2; exit 1; }
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$label" "$scen" "$shards" "$pairs" "$aa" "$ref" "$id" | tee -a "$OUT/runs.tsv"
    done <<< "$sel"
    [ "$DRY" = 1 ] || echo "release-check: dispatched; when the runs finish: bash $0 collect --out $OUT" ;;
  collect)
    [ -f "$OUT/runs.tsv" ] || { echo "release-check: no $OUT/runs.tsv (dispatch first)" >&2; exit 2; }
    [ ! -f "$OUT/candidate.txt" ] || echo "candidate: $(head -1 "$OUT/candidate.txt")"; echo
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
  *) usage ;;
esac
