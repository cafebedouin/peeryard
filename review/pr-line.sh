#!/usr/bin/env bash
# pr-line.sh: the `line` input of pr-scenario.yml for one pull request, and the dispatch command with the PR's head
# as read now. pr-scenario builds the base arm from `line` and the candidate from `line` + the PR's diff, and refuses a
# PR whose merge base is not an ancestor of the line's commit; `line` takes a release tag, a 40-hex commit or matrix /
# matrix-stack, never a branch name. So the right line is the PR's own merge base (its base branch, never the API's
# file list), named as a tag when a release tag points at it:
#
#   base branch weak-blocks   matrix, when the merge base is the weak-blocks commit peeryard carries
#                             (patches/ergo-matrix/patches.json) or an ancestor of it; otherwise no line (exit 3: the
#                             carried commit is older than the PR's base, and only the matrix lines build weak-blocks)
#   any other base branch     a release tag (vN.N.N) that points at a merge base; else the merge base itself, 40 hex
#                             (several merge bases, a criss-cross history: the one with the smallest diff to the head,
#                             as review/pick.sh chooses, after any tagged one)
#   --prefer-release          before the 40-hex fallback: the newest release tag that has the merge base as an
#                             ancestor, is itself an ancestor of the base branch's tip, and on which the PR's production
#                             diff applies (git apply --check); the base arm is then that release, not the commit the
#                             PR was written on, and the output says so
#
#   bash review/pr-line.sh --pr N [--repo ergoplatform/ergo] [--clone DIR] [--scenario S] [--shards K] [--pairs P]
#                          [--scenario-env 'KEY=VALUE;...'] [--ref BRANCH] [--peeryard owner/name] [--prefer-release]
#                          [--line-only] [--pr-json FILE]
#
# Prints comment lines (# ...: base branch and tip, head, merge bases, tags at them, the rule that chose the line) and
# then the command (or only the line, --line-only). It dispatches nothing; run the printed command after sizing the
# batch (CLAUDE.md, GitHub Actions usage). The head is the API's head.sha checked against the fetched pull/N/head, so
# the command carries the head as of this run; pr-scenario fails if the PR moves before it runs.
# Needs gh (authenticated, read-only), jq, git and a clone of the repository (--clone, default $DIFFRUN_ERGO_CLONE; a
# partial clone is fine); it fetches the base branch, pull/N/head (as pr-N) and the release tags into it.
# --pr-json FILE reads the pull request from a recorded API reply instead of gh (tests/pr_line.sh, offline replays).
# Exit: 0 printed; 2 usage; 3 no line can be named (the reason is printed); 4 the head moved while being read.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; ROOT="$(dirname "$HERE")"
REPO=ergoplatform/ergo; CLONE="${DIFFRUN_ERGO_CLONE:-}"; PR=""; SCEN=matrix-paychain; SHARDS=5; PAIRS=1; SENV=""
REF=main; PEERYARD=cafebedouin/peeryard; PREFER=0; LINE_ONLY=0; PRJSON=""
usage(){ sed -n '2,32p' "$0" >&2; exit 2; }
while [[ $# -gt 0 ]]; do case "$1" in
  --pr) PR="$2"; shift 2 ;; --repo) REPO="$2"; shift 2 ;; --clone) CLONE="$2"; shift 2 ;;
  --scenario) SCEN="$2"; shift 2 ;; --shards) SHARDS="$2"; shift 2 ;; --pairs) PAIRS="$2"; shift 2 ;;
  --scenario-env) SENV="$2"; shift 2 ;; --ref) REF="$2"; shift 2 ;; --peeryard) PEERYARD="$2"; shift 2 ;;
  --prefer-release) PREFER=1; shift ;; --line-only) LINE_ONLY=1; shift ;; --pr-json) PRJSON="$2"; shift 2 ;;
  -h|--help) usage ;; *) echo "pr-line: unknown argument $1" >&2; usage ;; esac; done
[[ "$PR" =~ ^[0-9]+$ ]] || { echo "pr-line: --pr N (a number)" >&2; exit 2; }
[[ -n "$CLONE" && -d "$CLONE" ]] || { echo "pr-line: --clone DIR (or DIFFRUN_ERGO_CLONE): a clone of $REPO" >&2; exit 2; }
[[ "$SCEN" =~ ^[a-z0-9-]+$ ]] || { echo "pr-line: --scenario: [a-z0-9-] only" >&2; exit 2; }
[[ "$SHARDS" =~ ^[1-9][0-9]?$ && "$SHARDS" -le 20 && "$PAIRS" =~ ^[1-9][0-9]?$ ]] || { echo "pr-line: --shards 1-20, --pairs 1-99" >&2; exit 2; }
[[ "$SENV" =~ ^[A-Za-z0-9._\ :,\;=-]*$ ]] || { echo "pr-line: --scenario-env: KEY=VALUE;... with [A-Za-z0-9._ :,-] values (diffrun/scenario-env.sh)" >&2; exit 2; }
[[ "$REF" =~ ^[A-Za-z0-9._/-]+$ ]] || { echo "pr-line: --ref: a branch name" >&2; exit 2; }
# the production paths pr-scenario.yml builds the candidate from (its PATHS; tests/pr_line.sh checks the two agree)
PATHS=(src/main ergo-core/src/main ergo-wallet/src/main avldb/src/main)
g(){ git -C "$CLONE" "$@"; }
die3(){ echo "# no line: $*"; exit 3; }

if [[ -n "$PRJSON" ]]; then pj="$(cat "$PRJSON")"; else pj="$(gh api "repos/$REPO/pulls/$PR")"; fi
B="$(jq -r '.base.ref // empty' <<< "$pj")"; H="$(jq -r '.head.sha // empty' <<< "$pj")"; ST="$(jq -r '.state // "?"' <<< "$pj")"
[[ "$B" =~ ^[A-Za-z0-9._/-]+$ && "$H" =~ ^[0-9a-f]{40}$ ]] || { echo "pr-line: #$PR: no base.ref / head.sha in the API reply" >&2; exit 2; }
read_at="$(date -u +%FT%TZ)"
g fetch -q origin "+refs/heads/$B:refs/remotes/origin/$B" || die3 "#$PR's base branch $B is not on origin (deleted after a merge?): use pr-scenario's patch mode (extra_patch with pr empty) on the line it merged into"
g fetch -q origin "+pull/$PR/head:refs/heads/pr-$PR"
g fetch -q origin "+refs/tags/v*:refs/tags/v*" 2>/dev/null || true
fh="$(g rev-parse "pr-$PR")"
[[ "$fh" == "$H" ]] || { echo "# #$PR moved while being read: the API says head $H, pull/$PR/head is $fh; run again" >&2; exit 4; }
TIP="$(g rev-parse "origin/$B")"
mapfile -t MBS < <(g merge-base --all "origin/$B" "pr-$PR" 2>/dev/null || true)
[[ ${#MBS[@]} -gt 0 ]] || die3 "#$PR shares no history with origin/$B"
# release tags only, as pr-scenario's line accepts them (^v[0-9.]+$); several at one commit: the highest version
tags_at(){ g tag --points-at "$1" --list 'v*' | { grep -E '^v[0-9.]+$' || true; } | sort -V | tail -1; }
echo "# #$PR ($ST) on $REPO: base branch $B (tip $TIP), head $H, read $read_at"
for mb in "${MBS[@]}"; do t="$(tags_at "$mb")"; echo "# merge base $mb$([[ -n "$t" ]] && echo " = $t")$([[ "$mb" == "$TIP" ]] && echo " (the branch tip)")"; done

LINE=""; WHY=""
if [[ "$B" == weak-blocks ]]; then
  pin="$(jq -r '.base // empty' "$ROOT/patches/ergo-matrix/patches.json" 2>/dev/null)"
  [[ "$pin" =~ ^[0-9a-f]{40}$ ]] || die3 "no carried weak-blocks commit in patches/ergo-matrix/patches.json"
  g cat-file -e "$pin^{commit}" 2>/dev/null || g fetch -q origin "$pin" || die3 "the carried weak-blocks commit $pin is not in the clone"
  for mb in "${MBS[@]}"; do
    if g merge-base --is-ancestor "$mb" "$pin"; then LINE=matrix; WHY="the merge base $mb is the carried weak-blocks commit or an ancestor of it ($pin)"; break; fi
  done
  [[ -n "$LINE" ]] || die3 "the merge base (${MBS[*]}) is newer than the weak-blocks commit peeryard carries ($pin): pr-scenario builds weak-blocks only on the matrix lines; move patches/ergo-matrix/patches.json's base forward first"
else
  # the PR's own merge base: of several, the one whose diff to the head is smallest (the diff GitHub shows)
  best=""; MB=""; for mb in "${MBS[@]}"; do c="$(g diff --name-only "$mb" "pr-$PR" | wc -l)"; if [[ -z "$best" || "$c" -lt "$best" ]]; then best="$c"; MB="$mb"; fi; done
  if [[ $PREFER == 1 ]]; then
    # the newest release on the base branch that contains every merge base and takes the PR's production diff, taken
    # as pr-scenario takes it on a line that is not a merge base: from git's merge base (origin/<base>...pr-N)
    d="$(mktemp)"; ix="$(mktemp)"; trap 'rm -f "$d" "$ix"' EXIT
    g diff --binary "$(g merge-base "origin/$B" "pr-$PR")" "pr-$PR" -- "${PATHS[@]}" > "$d"
    while read -r t; do
      [[ -n "$t" ]] || continue
      g merge-base --is-ancestor "$t" "origin/$B" || continue
      a=1; for mb in "${MBS[@]}"; do g merge-base --is-ancestor "$mb" "$t" || a=0; done; [[ $a == 1 ]] || continue
      rm -f "$ix"
      if GIT_INDEX_FILE="$ix" git -C "$CLONE" read-tree "$t^{tree}" && GIT_INDEX_FILE="$ix" git -C "$CLONE" apply --cached --check "$d" 2>/dev/null; then
        LINE="$t"
        if [[ "$(g rev-parse "$t^{commit}")" == "$MB" ]]; then WHY="--prefer-release: $t is the merge base itself"
        else WHY="--prefer-release: the merge base $MB is an ancestor of $t, $t is on $B, and the PR's production diff applies on it; the base arm is $t, not the commit the PR was written on"; fi
        break
      fi
    done < <(g tag --list 'v*' --merged "origin/$B" | { grep -E '^v[0-9.]+$' || true; } | sort -rV)
    [[ -n "$LINE" ]] || echo "# --prefer-release: no release on $B contains the merge base and takes the diff; the exact rule follows"
  fi
  if [[ -z "$LINE" ]]; then
    for mb in "${MBS[@]}"; do t="$(tags_at "$mb")"; if [[ -n "$t" ]]; then LINE="$t"; WHY="a release tag points at the merge base ($mb)"; break; fi; done
  fi
  [[ -n "$LINE" ]] || { LINE="$MB"; WHY="no release tag at the merge base: the merge base itself (the base arm is the commit the PR was written on)"; }
fi
echo "# line: $LINE ($WHY)"
if [[ $LINE_ONLY == 1 ]]; then echo "$LINE"; exit 0; fi
cmd="gh workflow run pr-scenario.yml -R $PEERYARD --ref $REF -f pr=$PR -f head=$H -f line=$LINE -f scenario=$SCEN -f shards=$SHARDS -f pairs=$PAIRS"
[[ -n "$SENV" ]] && cmd+=" -f 'scenario_env=$SENV'"
echo "# jobs: 1 build + $SHARDS shard(s) of $PAIRS pair(s) + 1 pool; size the day's batch before running it"
echo "$cmd"
