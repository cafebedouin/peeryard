"""Classify each run's PR diff as near/far (prereg 'Near paths'), from git alone.
usage: classify.py <repo> <run_pr.tsv> > pr_class.tsv
For the release-branch runs (#2719 v6.0.9 head, #2640 v6.0.8 head) the class is 'pristine'.
"""
import csv, subprocess, sys, fnmatch

NEAR = [
    "src/it/*",
    "src/main/scala/org/ergoplatform/network/*",
    "src/main/scala/scorex/core/network/*",
    "src/main/scala/org/ergoplatform/nodeView/ErgoNodeViewHolder.scala",
    "*/nodeView/history/*",
    "*/nodeView/state/*",
    "*/mining/*",
    "src/main/resources/*.conf",
]
EXCEPT = ["*/nodeView/history/extra/*"]


def near(path):
    p = path if "/" in path else path
    if any(fnmatch.fnmatch(p, e) or fnmatch.fnmatch("/" + p, e) for e in EXCEPT):
        return False
    return any(fnmatch.fnmatch(p, n) or fnmatch.fnmatch("/" + p, n) for n in NEAR)


def git(repo, *a):
    return subprocess.run(["git", "-C", repo, *a], capture_output=True, text=True, check=True).stdout


repo, tsv = sys.argv[1], sys.argv[2]
rows = list(csv.reader(open(tsv), delimiter="\t"))[1:]
w = csv.writer(sys.stdout, delimiter="\t", lineterminator="\n")
w.writerow(["run", "pr", "epoch", "head", "base", "class", "n_files", "near_files"])
for r in rows:
    run, owner, branch, head, base, epoch, pr = r[0], r[2], r[3], r[4], r[5], r[6], r[7]
    if not epoch:
        continue
    if owner == "ergoplatform" and branch in ("v6.0.9", "v6.0.8"):
        w.writerow([run, pr, epoch, head[:9], base[:9], "pristine", 0, ""])
        continue
    mb = git(repo, "merge-base", base, head).strip()
    files = [f for f in git(repo, "diff", "--name-only", mb, head).split("\n") if f]
    nf = [f for f in files if near(f)]
    w.writerow([run, pr, epoch, head[:9], base[:9], "near" if nf else "far", len(files), ";".join(nf)])
