#!/usr/bin/env bash
# uncles-compare.sh: re-run the header-level input-block uncles measurement on GitHub-hosted runners and print
# the per-run readings.
#
# What it shows: on Matrix (ergoplatform/ergo weak-blocks b2a9e7b00), two builds side by side in every dispatch:
#   p1 = current design (b2a9e7b00 + a current-design patch stack, cafebedouin/ergo 80f638555) + #2562;
#   ph = header-level credit, final build (cafebedouin/ergo matrix-uncles-header at
#   56abfc61f, + #2562, flag on). In the mixed dispatches only ph runs, with one node's flag off; its artifact
#   label is then p1 (builds.txt names the patch).
#   The rig captures every P2P frame and every node, miner and payment log. The run prints, per run:
#   - bytes per Matrix node by message group;
#   - BlockTransactions requests per received ordering block;
#   - credited uncles and how many of their transactions were already on the chain;
#   - credit agreement between nodes, and per-node unanswered sibling body requests (BODYREQ);
#   - the external miner's refused share of input-block submissions.
# What counts against the issue's claims:
#   - p1 refused share near 0 in the external-miner arms (refusals are one part of the issue's waste figure);
#   - ph credit agreement far from the published 0.9947 (1.000, or below 0.98);
#   - BlockTransactions requests per received ordering block below 1.0;
#   - BODYREQ unanswered > 0 on a node in a mixed run.
# Fixed before the runs: every input below. The published runs used the rig at peeryard commit 6003c57 (branch
# matrix-value-instr). The refused share printed here is a whole-log count (warm-up included). The issue's waste
# figure (refused + orphaned, in the window) and its bootstrap intervals come from a separate log analyzer.
#
# Run card:
#   needs:   bash 4+, gh (authenticated; dispatch permission on REPO), jq, python3, sha256sum; nothing local is built.
#   time:    21 dispatches; each took 2.7 h wall time on GitHub-hosted runners (4.2-4.8 h for the two 120 s cells).
#   touches: only WORKDIR (default ./uncles-compare-out); no sudo.
#   stop:    Ctrl-C stops the waiting; cancel dispatched runs with `gh run cancel <id> -R $REPO`.
#   quick:   QUICK=1 dispatches one cell (m2, external miner, below the cap, both builds) instead of 21.
#   pin:     the script refuses to dispatch if REF's head is not 6003c57 (ALLOW_HEAD=1 overrides; workflow
#            dispatch can name a branch, not a commit).
set -euo pipefail

REPO=${REPO:-cafebedouin/peeryard}
REF=${REF:-matrix-value-instr}
PIN=6003c57d2a5a6cec46424ca583f7ddc2cce95948
WORKDIR=${WORKDIR:-./uncles-compare-out}
WF=patch-compare.yml
BASE=b2a9e7b00fd0ff76b0080d1c030b9df30ce768f6
P1=patches/ergo-matrix/candidates/abl-008-010-012-013-014-015-2562-on-b2a9e7b00-v2.patch
PH=patches/ergo-matrix/candidates/abl-v2-uncles-header-r6-2562-on-on-b2a9e7b00.patch
declare -A SHA=(
  ["$P1"]=96bd06b18f9b96c4f68d614d33a5025892f50b1f58ca544f21bfd1ccd05738d4
  ["$PH"]=915fc7c5155268d017accd431cb3ed231fe785ccf541ba5f15f90fe9e114942f
)

for t in gh jq python3 sha256sum; do command -v "$t" >/dev/null || { echo "missing: $t"; exit 2; }; done
mkdir -p "$WORKDIR"
head_sha=$(gh api "repos/$REPO/commits/$REF" --jq .sha)
echo "repo $REPO ref $REF head $head_sha (published runs: $PIN)"
if [ "$head_sha" != "$PIN" ] && [ "${ALLOW_HEAD:-0}" != 1 ]; then
  echo "REF head differs from the pinned rig commit; set ALLOW_HEAD=1 to run anyway"; exit 2
fi
for p in "$P1" "$PH"; do
  got=$(gh api -H "Accept: application/vnd.github.raw" "repos/$REPO/contents/$p?ref=$REF" | sha256sum | cut -d' ' -f1)
  [ "$got" = "${SHA[$p]}" ] || { echo "patch sha256 differs on $REF: $p ($got)"; exit 2; }
  echo "patch $p sha256 $got"
done

dispatch() {  # example arm load txload steady compat_s node_conf patches
  local ex=$1 arm=$2 load=$3 tx=$4 steady=$5 secs=$6 conf=$7 patches=$8 ext="" strict=false id
  case $arm in R1) ext=1s ;; S1) ext=1s; strict=true ;; I) ext="" ;; esac
  gh workflow run "$WF" -R "$REPO" --ref "$REF" \
    -f patches="$patches" -f example="$ex" -f repeats=2 -f compat_s="$secs" -f compat_poll=500ms \
    -f txload="$tx" -f extmine_poll="$ext" -f extmine_strict="$strict" -f ref_fairminer=true -f matrix_base="$BASE" \
    -f steady_from_h="$steady" -f wire=true -f versions=v4 -f base_runs=false -f txload_fund_split=300 \
    -f txload_nodes=matrix -f txload_per_node=true -f node_conf="$conf" -f txload_confirmed_only=true >&2
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    sleep 6
    id=$(gh run list -R "$REPO" --workflow "$WF" --branch "$REF" --event workflow_dispatch --limit 5 \
           --json databaseId --jq '.[].databaseId' | while read -r r; do
             case "$seen" in *" $r "*) ;; *) echo "$r"; break ;; esac; done)
    [ -n "$id" ] && break
  done
  [ -n "$id" ] || { echo "could not find the run just dispatched" >&2; exit 3; }
  echo "$id"
}
# ids of runs that already exist are not ours
seen=" $(gh run list -R "$REPO" --workflow "$WF" --branch "$REF" --limit 20 --json databaseId --jq '.[].databaseId' | tr '\n' ' ')"

ids=()
add() { local cell=$1; shift; local id; id=$(dispatch "$@"); seen="$seen$id "; ids+=("$id $cell"); }
core=matrix-compat
if [ "${QUICK:-0}" = 1 ]; then
  add core-m2-R1-U "$core-m2" R1 U 12 113 1200 "" "$P1 $PH"
else
  for topo in 2m2r-all 3m1r m2; do for arm in R1 I; do for load in S U; do
    [ "$load" = S ] && tx=50 || tx=12
    add "core-$topo-$arm-$load" "$core-$topo" "$arm" "$load" "$tx" 113 1200 "" "$P1 $PH"
  done; done; done
  for topo in 2m2r-all 3m1r m2; do
    add "strict-$topo-S1-U" "$core-$topo" S1 U 12 113 1200 "" "$P1 $PH"
  done
  add mixed-3m1r-R1-S-Coff     "$core-3m1r"     R1 S 50 113 1200 'C:ergo.node.inputBlockUncles=false' "$PH"
  add mixed-2m2r-all-R1-S-Boff "$core-2m2r-all" R1 S 50 113 1200 'B:ergo.node.inputBlockUncles=false' "$PH"
  add mixed-3m1r-R1-U-Coff     "$core-3m1r"     R1 U 12 113 1200 'C:ergo.node.inputBlockUncles=false' "$PH"
  add mixed-2m2r-all-R1-U-Boff "$core-2m2r-all" R1 U 12 113 1200 'B:ergo.node.inputBlockUncles=false' "$PH"
  add 120s-R1-U "$core-2m2r-all-120s" R1 U 2 65 5400 "" "$P1 $PH"
  add 120s-I-U  "$core-2m2r-all-120s" I  U 2 65 5400 "" "$P1 $PH"
fi
printf '%s\n' "${ids[@]}" > "$WORKDIR/dispatches.txt"
echo "dispatched ${#ids[@]}; list in $WORKDIR/dispatches.txt"

for line in "${ids[@]}"; do
  id=${line%% *}; cell=${line#* }
  gh run watch "$id" -R "$REPO" --exit-status >/dev/null || echo "WARN run $id ($cell) did not succeed"
  gh run download "$id" -R "$REPO" -D "$WORKDIR/$id" -p 'run-*' >/dev/null
done

python3 - "$WORKDIR" "${SHA[$P1]:0:16}" "${SHA[$PH]:0:16}" <<'PY'
import gzip, os, re, sys
work, want = sys.argv[1], set(sys.argv[2:4])
cells = dict(l.split(None, 1) for l in open(os.path.join(work, "dispatches.txt")).read().split("\n") if l.strip())
bad = 0
for rid, cell in cells.items():
    root = os.path.join(work, rid)
    if not os.path.isdir(root):
        print(f"== {cell.strip()} {rid}: no artifacts"); bad += 1; continue
    expect = 2 if cell.strip().startswith("mixed") else 4   # repeats=2 x builds in the dispatch
    found = 0
    for art in sorted(a for a in os.listdir(root) if a.startswith("run-")):
        run = os.path.join(root, art, art[4:])
        if not os.path.isfile(os.path.join(run, "value.txt")):
            print(f"== {cell.strip()} {rid} {art}: no run directory or value.txt"); bad += 1
            continue
        found += 1
        b = open(os.path.join(run, "builds.txt")).read()
        got = re.findall(r"^p\d+: .*\(sha256 ([0-9a-f]{16})\)", b, re.M)
        names = dict(re.findall(r"^(p\d+): .*/([^/ ]+\.patch)", b, re.M))
        if not got or not set(got) <= want:
            print(f"{art}: patch sha256 differs from the published runs: {got}"); bad += 1
        print(f"== {cell.strip()} {rid} {art[4:]} build {names.get(art[4:6], '?')}")
        for l in open(os.path.join(run, "value.txt")):
            if l.startswith(("BYTES A", "BYTES B", "REQUESTS wire", "VALUE", "CREDIT", "NODE final", "LOAD ordering",
                             "BODYREQ")):
                print("  " + l.rstrip()[:240])
        for f in sorted(os.listdir(os.path.join(run, "load"))):
            if f.startswith("extminer_"):
                codes = re.findall(r"submit kind=input .*?-> (\d+)", gzip.open(os.path.join(run, "load", f), "rt").read())
                n = len(codes); ok = codes.count("200")
                print(f"  {f[9:10]}: input submissions {n}, refused {n - ok} ({(n - ok) / n if n else 0:.3f}, whole log)")
    if found != expect:
        print(f"== {cell.strip()} {rid}: {found} runs, expected {expect}"); bad += 1
print("VERDICT", "OK" if bad == 0 else f"CHECK ({bad} problems)")
sys.exit(1 if bad else 0)
PY
