"""Unit tests for diag/health.py (node health) and its use in diag/compare_pool.py.
Run: python3 -m unittest tests/health_test.py"""
import io
import json
import os
import subprocess
import sys
import tempfile
import time
import unittest
from contextlib import redirect_stdout

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "diag"))
import health  # noqa: E402
import compare_pool  # noqa: E402

FIX = os.path.join(HERE, "fixtures", "health")


def write(d, name, text):
    with open(os.path.join(d, name), "w") as f:
        f.write(text)


class Controls(unittest.TestCase):
    """The run the check was asked for: patch-compare 37306440981, p1-v3 (restart loop) against p1-v4 (clean)."""

    def test_p1_v3_restart_loop_is_unhealthy(self):
        r = health.analyze(os.path.join(FIX, "p1-v3-1"))
        self.assertEqual(r["unhealthy"], {"A": ["RESTART_LOOP"]})
        top = r["nodes"]["A"]["restart_loops"][0]
        self.assertEqual(top["count"], 230779)
        self.assertIn("OneForOneStrategy - key not found: 9", top["message"])

    def test_p1_v4_same_dispatch_is_healthy(self):
        r = health.analyze(os.path.join(FIX, "p1-v4-1"))
        self.assertEqual(r["unhealthy"], {})
        self.assertEqual(r["nodes"]["A"]["restart_lines"], 0)

    def test_cli_exit_codes(self):
        with redirect_stdout(io.StringIO()):
            self.assertEqual(health.main([os.path.join(FIX, "p1-v3-1")]), 1)
            self.assertEqual(health.main([os.path.join(FIX, "p1-v4-1")]), 0)
            with tempfile.TemporaryDirectory() as d:
                self.assertEqual(health.main([d]), 2)

    def test_compare_pool_turns_the_pass_into_fail(self):
        out = io.StringIO()
        with redirect_stdout(out):
            compare_pool.main(FIX)
        text = out.getvalue()
        self.assertIn("p1-v3-1: A=RESTART_LOOP", text)
        self.assertIn("verdicts with health judged {'FAIL': 1}", text)
        self.assertIn("health: 0 of 1 runs with an unhealthy node", text)


class NodeLogs(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.mkdtemp()

    def log(self, node, text):
        write(self.d, f"node_{node}.log", text)

    def test_clean_log(self):
        self.log("A", "==== [rig] (re)launch A 2026-10-05T12:00:00+00:00 kind=jvm jar=x.jar mining=cfg poll=cfg cpus=rig ====\n"
                      "12:00:01.000 INFO  [main] o.e.ErgoApp - started\n"
                      "12:00:02.000 ERROR [d-5] o.e.m.ErgoMiningThread - Accepting solution or preparing candidate did not succeed\n")
        r = health.analyze(self.d)
        self.assertEqual(r["unhealthy"], {})
        self.assertEqual(r["nodes"]["A"]["launches"], 1)

    def test_oom_fatal_and_unplanned_exit(self):
        self.log("B", "12:00:01.000 INFO  [main] o.e.ErgoApp - started\n"
                      "Exception in thread \"dispatcher-7\" java.lang.OutOfMemoryError: Java heap space\n"
                      "# A fatal error has been detected by the Java Runtime Environment:\n"
                      "==== [rig] exit B pid=4242 2026-10-05T12:00:09+00:00 unplanned ====\n")
        r = health.analyze(self.d)
        self.assertEqual(r["unhealthy"], {"B": ["NODE_EXIT", "NODE_OOM", "JVM_FATAL"]})
        self.assertEqual(r["nodes"]["B"]["exits"], [{"pid": 4242, "at": "2026-10-05T12:00:09+00:00"}])

    def test_restart_loop_threshold_and_ids_folded(self):
        lines = "".join(f"12:00:{i % 60:02d}.000 ERROR [d] a.actor.OneForOneStrategy - no block {('%064x' % i)}\n" for i in range(25))
        self.log("A", lines)
        r = health.analyze(self.d)
        self.assertEqual(r["unhealthy"], {"A": ["RESTART_LOOP"]})
        self.assertEqual(r["nodes"]["A"]["restart_loops"][0]["count"], 25)    # 25 different ids, one message
        self.assertEqual(health.analyze(self.d, loop_min=26)["unhealthy"], {})

    def test_window(self):
        lines = "".join(f"12:{m:02d}:00.000 WARN  [d] o.e.m.ErgoMiningThread - Attempted mining thread restart\n" for m in range(40))
        self.log("A", lines)
        self.assertEqual(health.analyze(self.d)["unhealthy"], {"A": ["RESTART_LOOP"]})
        self.assertEqual(health.analyze(self.d, window=("12:30:00", "12:45:00"))["unhealthy"], {})   # 10 lines in it

    def test_report_only(self):
        self.log("B", "==== [rig] exit B pid=1 2026-10-05T12:00:09+00:00 unplanned ====\n")
        self.log("A", "12:00:01.000 INFO  [main] o.e.ErgoApp - started\n")
        r = health.analyze(self.d, report_only={"B"})
        self.assertEqual(r["unhealthy"], {})
        self.assertEqual(r["nodes"]["B"]["codes"], ["NODE_EXIT"])
        self.assertTrue(any("(report only)" in l for l in health.report(r)))

    def test_gzipped_artifact_layout_wins_over_counts(self):
        import gzip
        os.mkdir(os.path.join(self.d, "nodes"))
        with gzip.open(os.path.join(self.d, "nodes", "node_A.log.gz"), "wt") as f:
            f.write("12:00:01.000 INFO  [main] o.e.ErgoApp - started\n")
        write(self.d, "errors-node_A.txt", " 99 a.actor.OneForOneStrategy - key not found: 9\n")
        r = health.analyze(self.d)
        self.assertEqual(r["nodes"]["A"]["source"], "log")
        self.assertEqual(r["unhealthy"], {})


class Watcher(unittest.TestCase):
    """The rig's exit watcher, on real processes: an unplanned exit is recorded, a planned one is not."""

    def test_unplanned_and_planned(self):
        d = tempfile.mkdtemp()
        a = subprocess.Popen(["sleep", "30"]); b = subprocess.Popen(["sleep", "30"])
        try:
            with open(os.path.join(d, "events.jsonl"), "w") as f:
                for n, p in (("A", a.pid), ("B", b.pid)):
                    f.write(json.dumps({"t": 1, "kind": "launch", "node": n, "pid": p}) + "\n")
            with redirect_stdout(io.StringIO()):
                health.watch(d, once=True)                        # both alive: nothing recorded
                self.assertFalse(os.path.exists(os.path.join(d, "node_A.log")))
                with open(os.path.join(d, "planned_exits"), "a") as f:
                    f.write(f"B {b.pid}\n")
                a.kill(); b.kill(); a.wait(); b.wait()
                health.watch(d, once=True)
        finally:
            for p in (a, b):
                if p.poll() is None:
                    p.kill()
        with open(os.path.join(d, "events.jsonl")) as f:
            evs = [json.loads(l) for l in f]
        exits = [e for e in evs if e["kind"] == "exit"]
        self.assertEqual([(e["node"], e["pid"]) for e in exits], [("A", a.pid)])
        self.assertFalse(os.path.exists(os.path.join(d, "node_B.log")))
        self.assertEqual(health.analyze(d)["unhealthy"], {"A": ["NODE_EXIT"]})

    def test_partial_line_waits(self):
        d = tempfile.mkdtemp()
        p = subprocess.Popen(["sleep", "30"])
        try:
            line = json.dumps({"t": 1, "kind": "launch", "node": "A", "pid": p.pid})
            with open(os.path.join(d, "events.jsonl"), "w") as f:
                f.write(line[:10])                                # a launch event still being written
            with redirect_stdout(io.StringIO()):
                health.watch(d, once=True)
        finally:
            p.kill(); p.wait()
        self.assertFalse(os.path.exists(os.path.join(d, "node_A.log")))


if __name__ == "__main__":
    unittest.main()
