#!/usr/bin/env python3
"""mutation_judge.py: did a test notice the mutation? One test, read from spec-compare.yml runs of an unmutated arm and
a mutant arm (patches/mutate.sh).

  python3 diag/mutation_judge.py <dir> --test '<test name, or a part of it>' --mutant <patch path> [--control <patch path|base>]

<dir> holds spec-compare job artifacts (any depth), each a directory with tree.txt ("base <sha> ..." and
"patch none (the base alone)" or "patch <path> sha256 <16 hex>"), the scalatest XML report (TEST-*.xml) and sbt.log.gz.
A job belongs to the mutant arm when its patch line names --mutant, to the control arm when it names --control
(`base`, the default: the base alone). In each job the test is pass, fail (a <failure> or <error> in its <testcase>, or
`- <name> *** FAILED ***` in the sbt log when there is no XML), or absent (not run: the class did not compile, the
job died).

  KILLED     the control passed in every job and the mutant failed in every job: the test guards what was removed
  SURVIVED   the control passed in every job and the mutant passed in at least one: the test misses the mutation
             (a mutant that fails in some jobs only is reported with its count, still SURVIVED)
  INVALID    the control did not pass in every job, or an arm has no job or an absent test: nothing to conclude

Prints one line per job and the verdict line `MUTATION: <VERDICT> (control <p>/<n> pass, mutant <f>/<n> fail)`.
Exit 0 KILLED, 1 SURVIVED, 3 INVALID. Standard library only.
"""
import argparse
import gzip
import os
import re
import sys
import xml.etree.ElementTree as ET


def jobs(root):
    for d, _, files in os.walk(root):
        if 'tree.txt' in files:
            yield d


def arm_of(d):
    with open(os.path.join(d, 'tree.txt'), errors='replace') as f:
        txt = f.read()
    m = re.search(r'^patch (\S+)', txt, re.M)
    return 'base' if (not m or m.group(1) == 'none') else m.group(1)


def outcome(d, test):
    found = []
    for f in sorted(os.listdir(d)):
        if f.endswith('.xml'):
            try:
                tree = ET.parse(os.path.join(d, f))
            except ET.ParseError:
                continue
            for tc in tree.iter('testcase'):
                if test in (tc.get('name') or ''):
                    bad = tc.find('failure') is not None or tc.find('error') is not None
                    found.append('fail' if bad else ('skipped' if tc.find('skipped') is not None else 'pass'))
    if found:
        return 'fail' if 'fail' in found else ('pass' if 'pass' in found else 'absent')
    for f in ('sbt.log.gz', 'sbt.log'):
        p = os.path.join(d, f)
        if os.path.exists(p):
            with (gzip.open(p, 'rt', errors='replace') if f.endswith('.gz') else open(p, errors='replace')) as fh:
                text = fh.read()
            text = re.sub(r'\x1b\[[0-9;]*m', '', text)
            lines = [l for l in text.splitlines() if l.startswith('[info] - ') and test in l]
            if lines:
                return 'fail' if any('*** FAILED ***' in l for l in lines) else 'pass'
    return 'absent'


def judge(root, test, mutant, control='base'):
    rows = []
    for d in sorted(jobs(root)):
        a = arm_of(d)
        norm = lambda p: p if p == 'base' else os.path.normpath(p)
        role = 'mutant' if norm(a) == norm(mutant) else ('control' if norm(a) == norm(control) else None)
        if role:
            rows.append((role, os.path.relpath(d, root), outcome(d, test)))
    c = [o for r, _, o in rows if r == 'control']; m = [o for r, _, o in rows if r == 'mutant']
    if not c or not m or 'absent' in c + m or any(o != 'pass' for o in c):
        v = 'INVALID'
    elif all(o == 'fail' for o in m):
        v = 'KILLED'
    else:
        v = 'SURVIVED'
    return v, rows, (sum(o == 'pass' for o in c), len(c), sum(o == 'fail' for o in m), len(m))


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('dir')
    ap.add_argument('--test', required=True)
    ap.add_argument('--mutant', required=True)
    ap.add_argument('--control', default='base')
    a = ap.parse_args(argv)
    v, rows, (cp, cn, mf, mn) = judge(a.dir, a.test, a.mutant, a.control)
    for role, d, o in rows:
        print(f'{role:7s} {o:7s} {d}')
    print(f'MUTATION: {v} (control {cp}/{cn} pass, mutant {mf}/{mn} fail; test "{a.test}")')
    return {'KILLED': 0, 'SURVIVED': 1}.get(v, 3)


if __name__ == '__main__':
    sys.exit(main())
