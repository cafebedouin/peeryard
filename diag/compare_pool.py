"""compare_pool.py <dir>: pool the runs of .github/workflows/patch-compare.yml per build and block version.

<dir> holds one directory per run, named <build>-<version>-<repeat> (e.g. p1-v4-3), each with the run's rig.log,
builds.txt (what each build is) and errors-node_<X>.txt (the node's ERROR lines, counted). Per build and version:
runs; the example's verdicts (MATRIX-<NAME>: PASS/FAIL); ban/blacklist lines; for each relay pair the matrix-compat
analysis reports (X->Y: mined, sent, received, and the stale-height rule's agreement), the pooled received/mined share
and its lowest per-run value; ERROR lines from the synchronizer and all ERROR lines by message; node health per run
(diag/health.py over the run's node logs or counted ERROR lines: process exits, OutOfMemoryError, restart loops), with
the verdict a run's PASS becomes when a node was unhealthy. Standard library."""
import collections
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import health  # noqa: E402


def main(root):
    runs = collections.defaultdict(list)
    builds_txt = ''
    for name in sorted(os.listdir(root)):
        m = re.fullmatch(r'(.+)-(v[34])-(\d+)', name)
        d = os.path.join(root, name)
        if not m or not os.path.isdir(d):
            continue
        log = open(os.path.join(d, 'rig.log'), errors='replace').read() if os.path.exists(os.path.join(d, 'rig.log')) else ''
        if not builds_txt and os.path.exists(os.path.join(d, 'builds.txt')):
            builds_txt = open(os.path.join(d, 'builds.txt')).read().strip()
        verdict = (re.findall(r'^MATRIX-[A-Z]+: (PASS|FAIL)', log, re.M) or ['NONE'])[-1]
        bans = sum(int(x) for x in re.findall(r'^MATRIX-COMPAT-BANS (\d+)', log, re.M))
        relay = {}
        for x, y, mined, sent, got, ok, tot in re.findall(
                r'relay (\w+)->(\w+): mined (\d+) sent (\d+) received (\d+); stale-height rule predicts (\d+)/(\d+)', log):
            if int(mined):
                relay[(x, y)] = (int(mined), int(sent), int(got), int(ok))
        errors = collections.Counter()
        for f in os.listdir(d):
            if f.startswith('errors-'):
                for line in open(os.path.join(d, f), errors='replace'):
                    cm = re.match(r'\s*(\d+) (.*)', line.rstrip('\n'))
                    if cm:
                        errors[re.sub(r'[0-9a-f]{64}', '<id>', cm.group(2))] += int(cm.group(1))
        h = health.analyze(d)
        unhealthy = sorted(f"{n}={','.join(c)}" for n, c in (h or {}).get('unhealthy', {}).items())
        runs[(m.group(1), m.group(2))].append(dict(name=name, verdict=verdict, bans=bans, relay=relay, errors=errors,
                                                   health=None if h is None else unhealthy))

    if builds_txt:
        print(builds_txt)
        print()
    for (build, version) in sorted(runs):
        rs = runs[(build, version)]
        verdicts = collections.Counter(r['verdict'] for r in rs)
        print(f'== {build} {version}: {len(rs)} runs; verdicts {dict(verdicts)}; ban/blacklist lines {sum(r["bans"] for r in rs)}')
        bad = [r for r in rs if r['health']]
        judged = collections.Counter('FAIL' if r['health'] and r['verdict'] == 'PASS' else r['verdict'] for r in rs)
        print(f'   health: {len(bad)} of {len(rs)} runs with an unhealthy node'
              + (f'; verdicts with health judged {dict(judged)}' if bad else '')
              + ''.join(f"\n     {r['name']}: {' '.join(r['health'])}" for r in bad)
              + (f"; not read in {sum(r['health'] is None for r in rs)} (no node log or error count)" if any(r['health'] is None for r in rs) else ''))
        pairs = sorted({p for r in rs for p in r['relay']})
        for p in pairs:
            vals = [r['relay'][p] for r in rs if p in r['relay']]
            mined = sum(v[0] for v in vals); sent = sum(v[1] for v in vals); got = sum(v[2] for v in vals)
            ok = sum(v[3] for v in vals)
            low = min(v[2] / v[0] for v in vals)
            print(f'   relay {p[0]}->{p[1]}: mined {mined} sent {sent} received {got} '
                  f'(received/mined {got / mined:.3f}, lowest run {low:.3f}); stale-height rule agrees {ok}/{mined}')
        err = sum((r['errors'] for r in rs), collections.Counter())
        sync_err = sum(c for k, c in err.items() if 'ErgoNodeViewSynchronizer' in k)
        print(f'   ERROR lines: {sum(err.values())}, of them ErgoNodeViewSynchronizer: {sync_err}')
        for k, c in err.most_common(6):
            print(f'     {c:5d} {k[:140]}')


if __name__ == '__main__':
    main(sys.argv[1])
