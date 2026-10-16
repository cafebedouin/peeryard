#!/usr/bin/env bash
# mutate.sh: a mutation arm. The tree a test or scenario passes on (a base, optionally with a candidate patch), with one
# deliberate textual change, written as one patch from the base, so it runs as just another arm wherever patches do
# (spec-compare.yml `patches`, patch-compare.yml, diffrun/build.sh <base> <file>). A test that guards a change must
# fail on the arm that takes the change out; one that still passes there does not test it (a surviving mutant).
#
#   bash patches/mutate.sh --clone <ergo clone> --base <ref> [--patch <candidate.patch>] --file <path in the tree>
#                          --remove '<literal text>' [--insert '<literal text>'] --out <mutant.patch>
#
# The text to remove must occur exactly once in <file> as the base (plus the candidate patch) has it: zero or several
# occurrences is an error that names the count, so a mutation never lands somewhere other than where it was meant.
# --insert (default: nothing) takes its place. The output is a diff from <base>: the candidate patch and the mutation
# together, applied alone to the base, as spec-compare and patch-compare apply each patch. Beside it,
# <mutant.patch>.mutation.json records the base, the candidate patch (path, sha256), the file, the removed and inserted
# text and the mutant's sha256; the mutation alone (candidate -> mutant) is printed on stderr. Nothing in the clone's
# checkout or refs changes: the trees are built in a temporary index (one new blob is written to its object store).
# The judge for spec-compare runs of the arms: diag/mutation_judge.py.
#
# A mutation changes the node under test, never what it is sent: a mutant runs as an honest node on a benign network
# (CONTRIBUTING.md, "The one rule"). It answers one question, whether a test or scenario notices a change being gone.
set -euo pipefail
die(){ echo "mutate: ERROR: $*" >&2; exit 2; }
CLONE="${DIFFRUN_ERGO_CLONE:-}"; BASE=""; PATCH=""; FILE=""; REMOVE=""; INSERT=""; OUT=""; have_remove=0
while [[ $# -gt 0 ]]; do case "$1" in
  --clone) CLONE="$2"; shift 2 ;; --base) BASE="$2"; shift 2 ;; --patch) PATCH="$2"; shift 2 ;; --file) FILE="$2"; shift 2 ;;
  --remove) REMOVE="$2"; have_remove=1; shift 2 ;; --insert) INSERT="$2"; shift 2 ;; --out) OUT="$2"; shift 2 ;;
  *) die "unknown argument $1 (see the header of $0)" ;; esac; done
[[ -n "$CLONE" && -n "$BASE" && -n "$FILE" && -n "$OUT" && $have_remove == 1 ]] || die "--clone (or DIFFRUN_ERGO_CLONE), --base, --file, --remove and --out are required"
[[ -n "$REMOVE" ]] || die "--remove is empty"
[[ "$REMOVE" != "$INSERT" ]] || die "--insert equals --remove: that is no mutation"
git -C "$CLONE" rev-parse --git-dir >/dev/null 2>&1 || die "not a git clone: $CLONE"
BASE_SHA="$(git -C "$CLONE" rev-parse --verify --quiet "$BASE^{commit}")" || die "base not found in the clone: $BASE"
[[ -z "$PATCH" || -f "$PATCH" ]] || die "no such patch file: $PATCH"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export GIT_INDEX_FILE="$TMP/index"
git -C "$CLONE" read-tree "$BASE_SHA"
if [[ -n "$PATCH" ]]; then git -C "$CLONE" apply --cached "$(readlink -f "$PATCH")" || die "the candidate patch does not apply to $BASE"; fi
entry="$(git -C "$CLONE" ls-files -s -- "$FILE")"; [[ -n "$entry" ]] || die "$FILE is not in the tree (base${PATCH:+ + candidate patch})"
mode="$(awk '{print $1}' <<< "$entry")"; blob="$(awk '{print $2}' <<< "$entry")"
git -C "$CLONE" cat-file blob "$blob" > "$TMP/before"
REMOVE="$REMOVE" INSERT="$INSERT" python3 - "$TMP/before" "$TMP/after" <<'EOF' || exit 2
import os, sys
src = open(sys.argv[1], encoding='utf-8', errors='surrogateescape').read()
rm, ins = os.environ['REMOVE'], os.environ['INSERT']
n = src.count(rm)
if n != 1:
    sys.stderr.write(f'mutate: ERROR: the text to remove occurs {n} times in the file (it must occur exactly once)\n'); sys.exit(2)
open(sys.argv[2], 'w', encoding='utf-8', errors='surrogateescape').write(src.replace(rm, ins))
EOF
new="$(git -C "$CLONE" hash-object -w "$TMP/after")"
git -C "$CLONE" update-index --cacheinfo "$mode,$new,$FILE"
mkdir -p "$(dirname "$OUT")"
git -C "$CLONE" diff --cached --binary "$BASE_SHA" > "$OUT"
[[ -s "$OUT" ]] || die "the mutant is identical to the base"
psha=null; [[ -n "$PATCH" ]] && psha="\"$(sha256sum "$PATCH" | cut -d' ' -f1)\""
jq -n --arg base "$BASE_SHA" --arg p "$PATCH" --argjson psha "$psha" --arg f "$FILE" --arg rm "$REMOVE" --arg ins "$INSERT" \
      --arg msha "$(sha256sum "$OUT" | cut -d' ' -f1)" \
  '{base: $base, candidate_patch: (if $p == "" then null else {path: $p, sha256: $psha} end), file: $f,
    removed: $rm, inserted: $ins, occurrences: 1, mutant_sha256: $msha}' > "$OUT.mutation.json"
echo "mutate: $OUT = base ${BASE_SHA:0:12}${PATCH:+ + $PATCH} with this change to $FILE:" >&2
diff -u --label "$FILE (unmutated)" --label "$FILE (mutant)" "$TMP/before" "$TMP/after" >&2 || true
echo "$OUT"
