#!/usr/bin/env python3
"""Self-test for santa-grade: the comparison finds planted differences and the controls fail when they should.

usage: grader_selftest.py <santa-grade> <vectors-dir> <runner.json> <base-label-dir> <scratch-dir> <leaf> [<leaf>...]

From the base label's actuals it builds, in <scratch-dir>:
  planted/     a copy with four planted edits on eval entries: one passing entry made to panic (expect regressed),
               one failing errored entry given the blessed expected outcome (expect fixed), one failing errored entry
               made to panic (expect verdict changed, same pass/fail), and one passing entry with a changed `cost`
               field, which a runner with cost=false is not graded on (expect output changed, same verdict);
  conflicted/  a manifest only, status merge-conflict (expect reported as not built, not graded).
Then it checks: with `planted` as a control santa-grade exits 1 and reports exactly the four planted entries in
their four classes; with an expected base count off by one on one leaf it exits 1; with the base's own counts and
an unchanged copy as the control it exits 0. Exit 0 = every check passed.
"""
import copy, json, os, shutil, subprocess, sys

grader, vectors, runner_json, base_dir, scratch = sys.argv[1:6]
leaves = sys.argv[6:]
if not leaves:
    sys.exit(__doc__)
os.makedirs(scratch, exist_ok=True)
claims_cost = json.load(open(runner_json)).get('cost', True)


def run(args, out_name):
    out = os.path.join(scratch, out_name)
    cmd = [grader, '--vectors', vectors, '--runner-json', runner_json, '--leaves', ' '.join(leaves),
           '--base', base_dir, '--json', out + '.json', '--summary', out + '.md'] + args
    r = subprocess.run(cmd, capture_output=True, text=True)
    return r.returncode, json.load(open(out + '.json')), r.stderr


# 1. Grade the base alone to learn which entries fail.
rc, base, err = run([], 'base-only')
assert rc == 0, f'base-only run exited {rc}: {err}'
failing = {(leaf, f['file'], f['entry']): f for leaf, v in base['base']['leaves'].items() for f in v['failing_entries']}


def actuals_path(root, leaf, op):
    return os.path.join(root, 'actuals', leaf, op + '.json')


# 2. Pick four eval entries on accept vectors (expected error null), in corpus order.
picks = {}
for leaf in leaves:
    if not leaf.startswith('eval/'):
        continue
    for fn in sorted(os.listdir(os.path.join(vectors, leaf))):
        if not fn.endswith('.json'):
            continue
        op = fn[:-5]
        vec = json.load(open(os.path.join(vectors, leaf, fn)))
        acts = json.load(open(actuals_path(base_dir, leaf, op)))
        for e in vec['entries']:
            if e['expected'].get('error') is not None or e['name'] not in acts:
                continue
            k = (leaf, op, e['name'])
            a = acts[e['name']]
            if k not in failing and a.get('error') is None:
                slot = 'regressed' if 'regressed' not in picks else 'output_changed' if 'output_changed' not in picks else None
            elif k in failing and failing[k]['outcome'] == 'errored':
                slot = 'fixed' if 'fixed' not in picks else 'verdict_changed' if 'verdict_changed' not in picks else None
            else:
                slot = None
            if slot:
                picks[slot] = (k, e)
assert len(picks) == 4, f'could not find four entries to plant, found {sorted(picks)}'

# 3. planted/: a copy of the base actuals with the four edits.
planted = os.path.join(scratch, 'planted')
shutil.rmtree(planted, ignore_errors=True)
for leaf in leaves:
    shutil.copytree(os.path.join(base_dir, 'actuals', leaf), os.path.join(planted, 'actuals', leaf))
for slot, ((leaf, op, name), e) in picks.items():
    p = actuals_path(planted, leaf, op)
    acts = json.load(open(p))
    if slot in ('regressed', 'verdict_changed'):
        acts[name] = {'value': None, 'cost': None, 'error': 'panicked', 'note': 'planted by grader_selftest.py'}
    elif slot == 'fixed':
        acts[name] = {'value': copy.deepcopy(e['expected'].get('value')), 'cost': e['expected'].get('cost'), 'error': None}
    else:  # output_changed: only the cost field, which a cost=false runner is not graded on
        assert not claims_cost, 'the output-changed plant needs a runner with cost=false'
        acts[name] = dict(acts[name], cost=987654321)
    json.dump(acts, open(p, 'w'))
    print(f'planted {slot}: {leaf} {op} {name}')

conflicted = os.path.join(scratch, 'conflicted')
shutil.rmtree(conflicted, ignore_errors=True)
os.makedirs(conflicted)
json.dump({'label': 'conflicted', 'change': 'pr:0', 'status': 'merge-conflict'}, open(os.path.join(conflicted, 'manifest.json'), 'w'))

checks = []


def check(name, ok, detail=''):
    checks.append(ok)
    print(f"{'PASS' if ok else 'FAIL'}: {name}{' (' + detail + ')' if detail else ''}")


# 4. planted as a control: exit 1, exactly the planted entries in their classes.
rc, out, _ = run(['--change', f'planted={planted}', '--change', f'conflicted={conflicted}', '--control', 'planted'], 'planted')
check('a control with planted differences fails (exit 1)', rc == 1, f'exit {rc}')
ch = out['changes']['planted']
for slot, ((leaf, op, name), _) in picks.items():
    got = [(i['leaf'], i['file'], i['entry']) for i in ch[slot]]
    check(f'{slot}: exactly the planted entry', got == [(leaf, op, name)], f'got {got}')
check('the planted panic is visible as a verdict change',
      ch['verdict_changed'][0]['base']['outcome'] == 'errored' and ch['verdict_changed'][0]['change']['outcome'] == 'panicked')
check('a label whose manifest says merge-conflict is reported, not graded',
      out['changes']['conflicted']['status'] == 'merge-conflict')

# 5. Expected counts: off by one on one leaf fails; the base's own counts with an unchanged copy pass.
own = {leaf: v['failing'] for leaf, v in base['base']['leaves'].items()}
first = leaves[0]
off = ' '.join(f'{l}={n + (1 if l == first else 0)}' for l, n in own.items())
rc, out, _ = run(['--expected', off], 'expected-off')
check('an expected count off by one fails (exit 1)', rc == 1 and any(first in f for f in out['control_failures']), f'exit {rc}')
same = os.path.join(scratch, 'same')
shutil.rmtree(same, ignore_errors=True)
for leaf in leaves:
    shutil.copytree(os.path.join(base_dir, 'actuals', leaf), os.path.join(same, 'actuals', leaf))
rc, out, _ = run(['--expected', ' '.join(f'{l}={n}' for l, n in own.items()), '--change', f'same={same}', '--control', 'same'],
                 'expected-own')
check('the base\'s own counts and an unchanged copy as control pass (exit 0)', rc == 0, f'exit {rc}')

print(f'selftest: {sum(checks)}/{len(checks)} checks passed')
sys.exit(0 if all(checks) else 1)
