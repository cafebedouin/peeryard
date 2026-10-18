"""Unit tests for the same-change view of queue/build.py (production patch-id groups and same-issue pairs), on a local
git repository with refs/pull/N/head refs; no network.
Run: python3 -m unittest tests/queue_same_change_test.py"""
import os
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "queue"))
import build  # noqa: E402

REPO = "o/r"


def sh(cwd, *args):
    return subprocess.run(args, cwd=cwd, check=True, capture_output=True, text=True).stdout.strip()


def commit(src, files, msg):
    for path, text in files.items():
        os.makedirs(os.path.join(src, os.path.dirname(path)), exist_ok=True)
        with open(os.path.join(src, path), "w") as f:
            f.write(text)
    sh(src, "git", "add", "-A")
    sh(src, "git", "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", msg)
    return sh(src, "git", "rev-parse", "HEAD")


def pr(n, author, created, head, title="", body="", draft=False, head_ref="topic", head_repo="fork/r"):
    return {"number": n, "user": {"login": author}, "created_at": created, "draft": draft, "title": title, "body": body,
            "html_url": f"https://github.com/{REPO}/pull/{n}", "base": {"ref": "master", "sha": ""},
            "head": {"sha": head, "ref": head_ref, "repo": {"full_name": head_repo}}}


class SameChange(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        src = os.path.join(cls.tmp.name, "src")
        os.makedirs(src)
        sh(src, "git", "init", "-q", "-b", "master")
        commit(src, {"src/main/A.scala": "a\n", "core/src/main/B.scala": "b\n", "src/test/T.scala": "t\n"}, "base")
        heads = {}
        # 1 and 2: the same production change (2 also edits a test); 3: a different change to the same file;
        # 4: a test-only change; 5: a change to another production file
        for n, files in {1: {"src/main/A.scala": "a1\n"},
                         2: {"src/main/A.scala": "a1\n", "src/test/T.scala": "t2\n"},
                         3: {"src/main/A.scala": "a3\n"},
                         4: {"src/test/T.scala": "t4\n"},
                         5: {"core/src/main/B.scala": "b5\n"}}.items():
            sh(src, "git", "checkout", "-q", "master")
            sh(src, "git", "checkout", "-q", "-b", f"p{n}")
            heads[n] = commit(src, files, f"pr {n}")
            sh(src, "git", "update-ref", f"refs/pull/{n}/head", heads[n])
        sh(src, "git", "update-ref", "refs/pull/6/head", heads[3])   # 6: from a release branch, at 3's head
        cls.gdir = os.path.join(cls.tmp.name, "cache.git")
        sh(cls.tmp.name, "git", "clone", "-q", "--bare", src, cls.gdir)
        cls.heads = heads

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def prs(self):
        h = self.heads
        return [pr(2, "bob", "2026-02-01T00:00:00Z", h[2], body="Fixes #9"),
                pr(1, "amy", "2026-01-01T00:00:00Z", h[1], draft=True, body="Closes #9"),
                pr(3, "cat", "2026-03-01T00:00:00Z", h[3], title="Refs #9 and #1"),
                pr(4, "dan", "2026-03-02T00:00:00Z", h[4], body="Fixes #9"),
                pr(5, "amy", "2026-03-03T00:00:00Z", h[5], body="see #8"),
                pr(6, "rel", "2026-03-04T00:00:00Z", h[3], body="#9 #8", head_ref="v1.2.3", head_repo=REPO),
                pr(10, "eve", "2026-03-05T00:00:00Z", "0" * 40, body="#9")]       # no ref: reported, not fatal

    def run_view(self, kinds):
        old = build.api
        build.api = lambda path, *a, **k: {"html_url": "u", "title": "t", "state": "open",
                                          **({"pull_request": {}} if kinds.get(int(path.rsplit("/", 1)[1])) == "pr" else {})}
        try:
            diffs = build.production_diffs(REPO, self.prs(), self.gdir)
            return (diffs,) + build.same_change(REPO, self.prs(), diffs, None, {"same_change": {"release_head": "^v[0-9]"}})
        finally:
            build.api = old

    def test_exact_group_earliest_first_draft_included(self):
        diffs, exact, related, meta = self.run_view({9: "issue", 8: "issue"})
        self.assertEqual(diffs[4], {"files": [], "patch_id": None})
        self.assertIn("error", diffs[10])
        self.assertEqual(diffs[1]["patch_id"], diffs[2]["patch_id"])
        self.assertNotEqual(diffs[1]["patch_id"], diffs[3]["patch_id"])
        groups = [g["prs"] for g in exact]
        self.assertIn([1, 2], groups)                    # draft 1 opened earlier: first
        self.assertIn([3, 6], groups)                    # same head: same change, whatever the branch

    def test_same_issue_pairs(self):
        _, exact, related, _ = self.run_view({9: "issue", 8: "issue"})
        by_issue = {g["issue"]: g for g in related}
        self.assertEqual(set(by_issue), {9})             # 8: only amy (5) and the release branch (6), left out
        pairs = [p["prs"] for p in by_issue[9]["pairs"]]
        self.assertEqual(sorted(pairs), [[1, 3], [2, 3]])  # 1-2 already one exact group; 4 shares no production file
        self.assertEqual(by_issue[9]["prs"], [1, 2, 3])

    def test_reference_to_a_pull_request_is_not_an_issue(self):
        _, _, related, _ = self.run_view({9: "pr", 8: "issue"})
        self.assertEqual(related, [])

    def test_issue_refs(self):
        p = pr(7, "x", "", "", title="Fix #12", body="Closes https://github.com/o/r/issues/34, not o/r#56 or &#78; self #7")
        self.assertEqual(build.issue_refs(REPO, p), {12, 34})


if __name__ == "__main__":
    unittest.main()
