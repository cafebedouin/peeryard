"""matrix_compat.py <rig log dir> <topology.json> [HH:MM:SS [HH:MM:SS]]: what a mixed or all-Matrix network did, from its node logs
(rig/examples/matrix-compat.sh runs it at the end of a run). Counts only events between the two marks (all miners
mining; the end mark precedes the relaunches that stop mining).
  relay      per ordered pair of Matrix nodes X->Y: input blocks X mined, sent to Y, Y processed; and how many of X's
             sends are predicted by "Y eligible iff |X full height - Y's height at its last SyncInfo to X| <= 2" (the
             relay filter's peer height is refreshed only by SyncInfo)
  ordering   ordering blocks mined per node; reorgs (a new best header not above the previous one)
  rollbacks  input-chain rollbacks per Matrix node (input-block processing that rolled back > 0 blocks)
  penalties  peer penalties by penalizer->penalized and type (reported: peers on an all-Matrix network penalize each other too)
  bans       ban / blacklist lines per node (the example gates on these)
The topology names each node's kind in "compat_kinds" ({"A": "M", "C": "R"}: Matrix or reference). Standard library."""
import itertools
import json
import os
import re
import sys


def ts(t):
    h, m, s = t.split(':')
    return int(h) * 3600 + int(m) * 60 + float(s)


def stamped(l):
    return re.match(r'\d\d:\d\d:\d\d\.\d+', l) is not None


def main(argv):
    d, topo = argv[0], argv[1]
    t0 = ts(argv[2]) if len(argv) > 2 else 0.0
    t1 = ts(argv[3]) if len(argv) > 3 else 1e9
    eff = json.load(open(os.path.join(d, 'effective.json')))
    kinds = json.load(open(topo)).get('compat_kinds', {})
    names = [n['name'] for n in eff['nodes']]
    ip2n = {n.get('id_ip'): n['name'] for n in eff['nodes']}
    logs = {n: open(os.path.join(d, f'node_{n}.log'), errors='replace').read().splitlines() for n in names}

    def heights(n):
        return [(ts(l[:12]), int(m.group(1))) for l in logs[n] if stamped(l)
                for m in [re.search(r'New best header \S+ with score \d+\. New height (\d+)', l)] if m]
    hs = {n: heights(n) for n in names}

    def h_at(n, t):
        v = [h for (x, h) in hs[n] if x <= t]
        return v[-1] if v else 0

    def remote(l):
        m = re.search(r'remote=/([0-9.]+):', l)
        return ip2n.get(m.group(1)) if m else None

    mat = [n for n in names if kinds.get(n) == 'M']
    mined, sends, sync = {}, {}, {}
    for x in names:
        mined[x] = [(i, ts(l[:12]), m.group(1)) for i, l in enumerate(logs[x]) if stamped(l) and t0 <= ts(l[:12]) <= t1
                    for m in [re.search(r'Input-block ([0-9a-f]{12})\S* mined @ height', l)] if m]
        sends[x] = [(i, remote(l)) for i, l in enumerate(logs[x]) if 'MessageSpec(100: SubBlock)' in l]
        for l in logs[x]:
            if stamped(l) and 'Send message MessageSpec(65' in l:
                sync.setdefault((x, remote(l)), []).append(ts(l[:12]))
    processed = {y: set(re.findall(r'Processing valid sub-block ([0-9a-f]{12})', '\n'.join(logs[y]))) for y in names}

    listing = ' '.join('%s:%s' % (n, kinds.get(n, '?')) for n in names)
    print('[matrix-compat] nodes %s; counting from %s' % (listing, argv[2] if len(argv) > 2 else 'start'))
    for x, y in itertools.permutations(mat, 2):
        mm, ss = mined[x], sends[x]
        sent = got = ok = 0
        for k, (i, t, ib) in enumerate(mm):
            nxt = mm[k + 1][0] if k + 1 < len(mm) else len(logs[x])
            s = any(i < j < nxt and r == y for (j, r) in ss)
            sent += s
            got += ib in processed[y]
            last = [u for u in sync.get((y, x), []) if u <= t]
            rep = h_at(y, last[-1]) if last else None
            ok += (rep is not None and h_at(x, t) - 2 <= rep <= h_at(x, t) + 2) == s
        print(f'[matrix-compat] relay {x}->{y}: mined {len(mm)} sent {sent} received {got}; stale-height rule predicts {ok}/{len(mm)}')
    orders = {n: sum(1 for l in logs[n] if stamped(l) and 'New block mined, header' in l and t0 <= ts(l[:12]) <= t1) for n in names}
    reorgs = {}
    for n in names:
        h = [v for (t, v) in hs[n] if t0 <= t <= t1]
        reorgs[n] = sum(1 for a, b in zip(h, h[1:]) if b <= a)
    rb = {}
    for n in mat:
        k = [int(m.group(1)) for l in logs[n] if stamped(l) and t0 <= ts(l[:12]) <= t1
             for m in [re.search(r'processing completed: \d+ forward, (\d+) rollback', l)] if m]
        rb[n] = f'{sum(1 for v in k if v > 0)} events/{sum(k)} blocks'
    # penalties are reported (peers on an all-Matrix network penalize each other too); bans and blacklists are gated
    pen = {}
    for n in names:
        for l in logs[n]:
            m = re.search(r'/([0-9.]+):\d+ penalized, penalty: (\w+)', l)
            if stamped(l) and t0 <= ts(l[:12]) <= t1 and m:
                key = '%s->%s %s' % (n, ip2n.get(m.group(1), m.group(1)), m.group(2))
                pen[key] = pen.get(key, 0) + 1
    hard = re.compile(r'(?i)\b(banned|blacklist(ed)?|ban(ning)? peer)\b')
    bans = {n: sum(1 for l in logs[n] if stamped(l) and t0 <= ts(l[:12]) <= t1 and hard.search(l)) for n in names}
    print(f'[matrix-compat] ordering blocks mined {orders}; reorgs {reorgs}')
    print(f'[matrix-compat] input-chain rollbacks {rb}')
    print(f'[matrix-compat] penalties (penalizer->penalized type: count) {dict(sorted(pen.items()))}')
    print(f'[matrix-compat] ban/blacklist lines {bans}')
    print(f'MATRIX-COMPAT-BANS {sum(bans.values())}')

if __name__ == '__main__':
    main(sys.argv[1:])
