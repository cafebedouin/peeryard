"""Unit tests for hygiene/report.py: base roles, issue clusters, the already-landed column (patch-id, cherry-pick and
squash) and the new-conflicts column (the merge base's own conflicts subtracted), on a local git repository with
refs/pull/N/head refs; no network.
Run: python3 -m unittest tests/hygiene_test.py"""
import os
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "hygiene"))
import report  # noqa: E402

LINES = [f"a{i}\n" for i in range(10)]


def sh(cwd, *args):
    return subprocess.run(args, cwd=cwd, check=True, capture_output=True, text=True).stdout.strip()


def commit(src, files, msg):
    for path, text in files.items():
        with open(os.path.join(src, path), "w") as f:
            f.write(text)
    sh(src, "git", "add", "-A")
    sh(src, "git", "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", msg)
    return sh(src, "git", "rev-parse", "HEAD")


def a_with(i, text):
    return "".join(LINES[:i] + [text + "\n"] + LINES[i + 1:])


class Hygiene(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        src = os.path.join(cls.tmp.name, "src")
        os.makedirs(src)
        sh(src, "git", "init", "-q", "-b", "master")
        commit(src, {"A.scala": "".join(LINES), "B.scala": "b\n", "C.scala": "c\n"}, "base")
        # the line diverges on A's line 1; an old branch changed the same line another way
        sh(src, "git", "checkout", "-q", "-b", "line")
        commit(src, {"A.scala": a_with(1, "a1 line")}, "line edits a1")
        sh(src, "git", "checkout", "-q", "master")
        sh(src, "git", "checkout", "-q", "-b", "old")
        commit(src, {"A.scala": a_with(1, "a1 old")}, "old edits a1")
        heads = {}
        # 1 (master): one commit, later cherry-picked into rel; 2 (master): two commits, squashed into rel as one;
        # 3 (master): edits a1, a new conflict with the line; 4 (old): edits B only, so its conflict with the line on A
        # is its merge base's, not its own; 5 (master): edits C, nowhere else; 6 (master): adds two lines to D, one of
        # which reaches rel inside another commit (landed edited: no patch-id match, half its content)
        for n, base, steps in [(1, "master", [{"B.scala": "b1\n"}]),
                               (2, "master", [{"C.scala": "c2\n"}, {"C.scala": "c2 more\n"}]),
                               (3, "master", [{"A.scala": a_with(1, "a1 pr3")}]),
                               (4, "old", [{"B.scala": "b4\n"}]),
                               (5, "master", [{"C.scala": "c5\n"}]),
                               (6, "master", [{"D.scala": "val landedLineOfCode = 1\nval notLandedLineHere = 2\n"}])]:
            sh(src, "git", "checkout", "-q", base)
            sh(src, "git", "checkout", "-q", "-b", f"p{n}")
            for k, files in enumerate(steps):
                heads[n] = commit(src, files, f"pr {n} step {k}")
            sh(src, "git", "update-ref", f"refs/pull/{n}/head", heads[n])
        sh(src, "git", "checkout", "-q", "master")
        sh(src, "git", "checkout", "-q", "-b", "rel")
        sh(src, "git", "-c", "user.name=m", "-c", "user.email=m@m", "cherry-pick", heads[1])
        commit(src, {"C.scala": "c2 more\n"}, "squash of pr 2")
        commit(src, {"D.scala": "val landedLineOfCode = 1\nsomething else\n"}, "part of pr 6, edited")
        cls.gdir = os.path.join(cls.tmp.name, "cache.git")
        sh(cls.tmp.name, "git", "clone", "-q", "--bare", src, cls.gdir)
        sh(cls.tmp.name, "git", "--git-dir", cls.gdir, "fetch", "-q", src, "+refs/pull/*:refs/pull/*")
        cls.prs = {n: {"number": n, "baseRefName": "old" if n == 4 else "master", "baseRefOid": ""} for n in heads}
        cls.ranges = {n: report.pr_range(cls.gdir, p) for n, p in cls.prs.items()}

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def test_roles(self):
        cfg = {"roles": {"current": ["v2"], "full": ["v1"], "dead": ["v0-RC1"], "line": ["line"], "master": ["master"]}}
        self.assertEqual([report.role_of(b, cfg) for b in ("v2", "v1", "v0-RC1", "line", "master", "topic")],
                         ["current", "full", "dead", "line", "master", "other"])

    def test_landed(self):
        out, missing = report.landed(self.gdir, self.ranges, ["rel", "line", "gone"])
        self.assertEqual(missing, ["gone"])
        self.assertEqual((out[1]["status"], out[1]["all_in"]), ("all", ["rel"]))          # cherry-pick: new sha, same patch-id
        self.assertEqual((out[2]["status"], out[2]["all_in"], out[2]["squash_in"]), ("all", [], ["rel"]))
        self.assertEqual((out[2]["commits"], out[2]["per_target"]["rel"]), (2, 0))
        self.assertEqual(out[3]["status"], "none")
        self.assertEqual(out[5]["status"], "none")                                         # same file as 2, other change
        self.assertEqual(out[6]["status"], "none")

    def test_content_present(self):
        out = report.content_present(self.gdir, self.ranges, ["rel", "line"])
        self.assertEqual(out[6], {"lines": 2, "present": {"rel": 1, "line": 0}})          # the edited landing patch-id misses
        self.assertEqual(out[3]["lines"], 0)                                               # "a1 pr3": shorter than MIN_LINE

    def test_new_conflicts(self):
        objects = sh(self.tmp.name, "git", "--git-dir", self.gdir, "count-objects")
        out, missing = report.new_conflicts(self.gdir, self.ranges, ["line"])
        self.assertEqual(missing, [])
        self.assertEqual(out[3]["line"], {"new": ["A.scala"], "count": 1, "at_head": 1, "at_merge_base": 0})
        self.assertEqual(out[4]["line"], {"new": [], "count": 0, "at_head": 1, "at_merge_base": 1})
        self.assertEqual(out[1]["line"]["count"], 0)
        # merge-tree's trees go to a scratch object directory: the clone gains no object
        self.assertEqual(sh(self.tmp.name, "git", "--git-dir", self.gdir, "count-objects"), objects)

    def test_clusters(self):
        repo = "o/r"
        cfg = {"release_head": "^v[0-9]"}
        prs = [{"number": n, "headRepository": {"nameWithOwner": "fork/r" if n != 13 else repo},
                "headRefName": "topic" if n != 13 else "v1.0.1"} for n in (10, 11, 12, 13)]
        links = {10: {"formal": [7], "text": []}, 11: {"formal": [], "text": [7]}, 12: {"formal": [8], "text": []},
                 13: {"formal": [7, 8], "text": []}}
        # 10 and 11 share issue 7 (formal and text); 12 is alone on 8 once the release-branch pull request 13 is left out
        self.assertEqual(report.clusters(repo, prs, links, cfg), {7: {10: "formal", 11: "text"}})


if __name__ == "__main__":
    unittest.main()
