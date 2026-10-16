#!/usr/bin/env bash
# build-train.sh: a composite of several ergoplatform/ergo pull requests as one patch, for pr-scenario.yml's patch mode
# (`extra_patch` with `pr` empty) or review/release-check.sh --patch. Each PR's production diff (<base branch>...<head>,
# the same production dirs pr-scenario.yml builds from) is applied in the order given on a detached worktree of the
# line's commit and committed; the output is the diff from the line's commit to the last commit, over those dirs. A PR
# whose diff does not apply on the PRs before it is recorded as CONFLICT and left out (the composite is then not the
# list given: say so). The per-PR table (number, head, merge base, files, diff sha256, apply) goes to stderr.
#
#   DIFFRUN_ERGO_CLONE=<ergo clone> bash patches/train/build-train.sh <line commit, 40 hex> <base branch> <pr>... > out.patch
#
# Needs network access to fetch the PRs (git fetch origin pull/<n>/head); the clone's origin must be ergoplatform/ergo.
set -euo pipefail
C="${DIFFRUN_ERGO_CLONE:?set DIFFRUN_ERGO_CLONE to an ergo clone}"
LINE="${1:?line commit}"; B="${2:?base branch}"; shift 2
[[ "$LINE" =~ ^[0-9a-f]{40}$ ]] || { echo "build-train: the line is a 40-hex commit" >&2; exit 2; }
[[ "$B" =~ ^[A-Za-z0-9._/-]+$ ]] || { echo "build-train: unexpected base branch name" >&2; exit 2; }
[[ $# -gt 0 ]] || { echo "build-train: no PRs given" >&2; exit 2; }
for n in "$@"; do [[ "$n" =~ ^[0-9]+$ ]] || { echo "build-train: PR '$n' is not a number" >&2; exit 2; }; done
PATHS=(src/main ergo-core/src/main ergo-wallet/src/main avldb/src/main)
refs=("+refs/heads/$B:refs/remotes/origin/$B"); for n in "$@"; do refs+=("+pull/$n/head:refs/heads/train-pr-$n"); done
git -C "$C" fetch -q origin "${refs[@]}"
git -C "$C" cat-file -e "$LINE^{commit}" 2>/dev/null || git -C "$C" fetch -q origin "$LINE"
W="$(mktemp -d)"; D="$(mktemp -d)"; trap 'git -C "$C" worktree remove --force "$W" >/dev/null 2>&1 || true; rm -rf "$W" "$D"' EXIT
git -C "$C" worktree add -q --detach "$W" "$LINE"
printf 'pr\thead\tmerge_base\tprod_files\tdiff_sha256\tapply\n' >&2
for n in "$@"; do
  d="$D/$n.diff"
  git -C "$C" diff --binary "origin/$B...train-pr-$n" -- "${PATHS[@]}" > "$d"
  files="$(git -C "$C" diff --name-only "origin/$B...train-pr-$n" -- "${PATHS[@]}" | wc -l)"
  r=ok; if git -C "$W" apply --index "$d" 2>/dev/null; then git -C "$W" -c user.name=train -c user.email=train@localhost commit -q -m "#$n"; else r=CONFLICT; fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$n" "$(git -C "$C" rev-parse "train-pr-$n")" "$(git -C "$C" merge-base "origin/$B" "train-pr-$n")" "$files" "$(sha256sum "$d" | cut -d' ' -f1)" "$r" >&2
done
git -C "$W" diff --binary "$LINE" HEAD -- "${PATHS[@]}"
