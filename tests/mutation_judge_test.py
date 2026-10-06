"""Unit tests for diag/mutation_judge.py on spec-compare-shaped job directories.
Run: python3 -m unittest tests/mutation_judge_test.py"""
import gzip
import io
import os
import sys
import tempfile
import unittest
from contextlib import redirect_stdout

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "diag"))
import mutation_judge as mj  # noqa: E402

TEST = "pass external ordering and input-block solutions to the candidate generator"
MUT = "patches/ergo-matrix/candidates/mutant-no-solutionfound-fallback-on-b2a9e7b00.patch"


def job(root, name, patch, result, via="xml"):
    d = os.path.join(root, name); os.makedirs(d)
    with open(os.path.join(d, "tree.txt"), "w") as f:
        f.write("base b2a9e7b00fd0ff76b0080d1c030b9df30ce768f6 (matrix_base input)\n"
                + ("patch none (the base alone)\n" if patch == "base" else f"patch {patch} sha256 0123456789abcdef\n"))
    if result == "absent":
        return
    if via == "xml":
        body = {"pass": "", "fail": '<failure message="timeout"/>'}[result]
        with open(os.path.join(d, "TEST-org.ergoplatform.mining.ErgoMinerSpec.xml"), "w") as f:
            f.write(f'<testsuite><testcase classname="org.ergoplatform.mining.ErgoMinerSpec" name="ErgoMiner should not include too costly transactions"/>'
                    f'<testcase classname="org.ergoplatform.mining.ErgoMinerSpec" name="ErgoMiner should {TEST}">{body}</testcase></testsuite>')
    else:
        with gzip.open(os.path.join(d, "sbt.log.gz"), "wt") as f:
            f.write(f"[info] - should {TEST}{' *** FAILED ***' if result == 'fail' else ''}\n")


def judge(root):
    with redirect_stdout(io.StringIO()):
        return mj.judge(root, TEST, MUT)[0]


class Verdicts(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.mkdtemp()

    def test_killed(self):
        for i in (1, 2):
            job(self.d, f"spec-c{i}", "base", "pass"); job(self.d, f"spec-m{i}", MUT, "fail")
        self.assertEqual(judge(self.d), "KILLED")
        with redirect_stdout(io.StringIO()):
            self.assertEqual(mj.main([self.d, "--test", TEST, "--mutant", MUT]), 0)

    def test_survived_even_once(self):
        job(self.d, "c1", "base", "pass"); job(self.d, "m1", MUT, "fail"); job(self.d, "m2", MUT, "pass")
        self.assertEqual(judge(self.d), "SURVIVED")

    def test_invalid_when_the_control_fails(self):
        job(self.d, "c1", "base", "fail"); job(self.d, "m1", MUT, "fail")
        self.assertEqual(judge(self.d), "INVALID")

    def test_invalid_when_the_test_did_not_run(self):
        job(self.d, "c1", "base", "pass"); job(self.d, "m1", MUT, "absent")
        self.assertEqual(judge(self.d), "INVALID")

    def test_invalid_without_a_mutant_arm(self):
        job(self.d, "c1", "base", "pass")
        self.assertEqual(judge(self.d), "INVALID")

    def test_sbt_log_when_no_xml(self):
        job(self.d, "c1", "base", "pass", via="log"); job(self.d, "m1", MUT, "fail", via="log")
        self.assertEqual(judge(self.d), "KILLED")

    def test_other_patches_are_ignored(self):
        job(self.d, "c1", "base", "pass"); job(self.d, "m1", MUT, "fail"); job(self.d, "x1", "patches/other.patch", "pass")
        self.assertEqual(judge(self.d), "KILLED")


if __name__ == "__main__":
    unittest.main()
