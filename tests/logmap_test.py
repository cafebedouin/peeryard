#!/usr/bin/env python3
"""Tests for diag/logmap.py: indexing log calls from Scala source (same-line and next-line messages, interpolations,
concatenations, enclosing owner and def) and matching log lines to them. No node source needed: synthetic files.

  python3 tests/logmap_test.py
"""
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "diag"))
import logmap as LM  # noqa: E402

SRC = '''package org.x

class Cache extends Logging {
  def tryToApply(k: K): Boolean = {
    log.warn(s"Modifier ${v.encodedId} is permanently invalid and will be removed from cache", e)
    false
  }
}

object Miner {
  private def start(): Unit = {
    log.info(
      s"Starting ${n} native miner(s)"
    )
    log.info("Plain message " + count)
  }
}
'''


class Index(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.TemporaryDirectory()
        os.makedirs(os.path.join(self.d.name, "src", "main"))
        with open(os.path.join(self.d.name, "src", "main", "Cache.scala"), "w") as f:
            f.write(SRC)
        os.makedirs(os.path.join(self.d.name, "src", "test"))
        with open(os.path.join(self.d.name, "src", "test", "Spec.scala"), "w") as f:
            f.write('class Spec { log.info("test only") }\n')
        self.lm = LM.LogMap(LM.build(self.d.name))

    def tearDown(self):
        self.d.cleanup()

    def test_same_line_interpolated(self):
        hits = self.lm.find("10:00:00.000 WARN  [t] o.x.Cache - Modifier ab12 is permanently invalid and will be removed from cache")
        self.assertEqual([(h["line"], h["owner"], h["def"]) for h in hits], [(5, "Cache", "tryToApply")])

    def test_next_line_message(self):
        hits = self.lm.find("10:00:00.000 INFO  [t] o.x.Miner$ - Starting 1 native miner(s)")
        self.assertEqual([(h["line"], h["owner"], h["def"]) for h in hits], [(12, "Miner", "start")])

    def test_concatenation_and_level(self):
        self.assertEqual(len(self.lm.find("10:00:00.000 INFO  [t] o.x.Miner$ - Plain message 42")), 1)
        self.assertEqual(self.lm.find("10:00:00.000 WARN  [t] o.x.Miner$ - Plain message 42"), [], "level must match")

    def test_tests_not_indexed_and_unknown_unmapped(self):
        self.assertEqual(self.lm.find("10:00:00.000 INFO  [t] o.x.Spec - test only"), [])
        self.assertEqual(self.lm.site("10:00:00.000 INFO  [t] o.x.Y - something else"), "(no source site)")


if __name__ == "__main__":
    unittest.main()
