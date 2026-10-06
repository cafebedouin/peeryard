#!/usr/bin/env python3
"""block_invariants.py: per-block invariants over the blocks a run's nodes held, and a hook for contract checks.

  python3 diag/block_invariants.py <blocks.jsonl> [--contract <cmd>]... [--agree-depth N] [--pool-lag N]
                                   [--max-report N] [--json <file>]

<blocks.jsonl> is what rig/lib/blockwatch.sh writes while a hook runs: one line per block a node held at one of the
monitor's polls, {"t_ms", "node", "h", "id", "block": <GET /blocks/<id>>}, and one line per pool read after new
blocks, {"t_ms", "node", "ev": "pool", "h": <the node's full height>, "ids": [<unconfirmed tx ids>]}.

These checks do not re-run consensus validation (the node already did; a re-implementation would mostly re-find its
own bugs). They check what the node reports about the blocks it accepted, each block on its own and against the
node's other blocks, its pool and the other nodes:

  link    the block's header names this height and id, and its parentId is a block the same node held one height
          below (when the monitor saw that height on that node)
  body    the node serves the block's transactions, at least one (the emission or fee transaction), and no
          transaction id twice in one block
  once    on each node's final chain, no transaction id is in two blocks
  pool    a transaction in a block at least --pool-lag (1) heights below the node's full height is no longer in the
          node's unconfirmed pool (a confirmed transaction left there is offered again to miners and wallets)
  agree   every pair of nodes holds the same block at each height at least --agree-depth (3) below the lowest final
          tip among them (a fork that never resolved; a node behind is not compared above its tip)
  contract:<name>   each --contract command, once per distinct block on the nodes' final chains: the block JSON on
          stdin, BLOCK_NODE / BLOCK_HEIGHT / BLOCK_ID in the environment; exit 0 = holds, otherwise the first line of
          its output is the reason. For a protocol's own checks (its boxes, registers, an off-chain record), written
          by whoever runs the scenario; rig/lib/invariants/deliberate-fail.sh is one that always fails, to show a
          violation reaches the verdict.

Prints the first --max-report (5) violations of each check and one summary line,
`INVARIANTS: OK blocks=<n> nodes=<n> checks=<list>` or `INVARIANTS: VIOLATED total=<n> <check>=<n> ...`.
Exit 0 none violated, 1 violated, 2 no block to check. Standard library only.
"""
import argparse
import collections
import json
import os
import shlex
import subprocess
import sys


def load(path):
    blocks, pools = [], []
    with open(path, errors='replace') as f:
        for line in f:
            try:
                r = json.loads(line)
            except ValueError:
                continue
            if r.get('ev') == 'pool':
                pools.append(r)
            elif isinstance(r.get('block'), dict) and r.get('node') and isinstance(r.get('h'), int):
                blocks.append(r)
    blocks.sort(key=lambda r: r.get('t_ms', 0)); pools.sort(key=lambda r: r.get('t_ms', 0))
    return blocks, pools


def txids(block):
    return [t.get('id') for t in ((block.get('blockTransactions') or {}).get('transactions') or [])]


def chain_at(blocks, node, t=None):
    """{h: record}: the latest record per height the node held up to time t (all of them when t is None)."""
    out = {}
    for r in blocks:
        if r['node'] == node and (t is None or r.get('t_ms', 0) <= t):
            out[r['h']] = r
    return out


def check(blocks, pools, contracts=(), agree_depth=3, pool_lag=1, timeout=30):
    v = collections.defaultdict(list)          # check -> [(node, h, id, reason)]
    nodes = sorted({r['node'] for r in blocks})
    held = collections.defaultdict(set)        # (node, h) -> ids ever held
    for r in blocks:
        held[(r['node'], r['h'])].add(r['id'])
    for r in blocks:
        hd = r['block'].get('header') or {}
        n, h, i = r['node'], r['h'], r['id']
        if hd.get('height') != h or hd.get('id') != i:
            v['link'].append((n, h, i, f"header says height {hd.get('height')} id {str(hd.get('id'))[:12]}"))
        below = held.get((n, h - 1))
        if below and hd.get('parentId') not in below:
            v['link'].append((n, h, i, f"parentId {str(hd.get('parentId'))[:12]} is none of the blocks the node held at {h - 1}"))
        ids = txids(r['block'])
        if not ids:
            v['body'].append((n, h, i, 'no transactions served'))
        dup = [x for x, c in collections.Counter(ids).items() if c > 1]
        if dup:
            v['body'].append((n, h, i, f'transaction {str(dup[0])[:12]} twice in the block'))
    finals = {n: chain_at(blocks, n) for n in nodes}
    for n, ch in finals.items():
        first = {}
        for h in sorted(ch):
            for x in set(txids(ch[h]['block'])):
                if x in first:
                    v['once'].append((n, h, ch[h]['id'], f'transaction {x[:12]} already in the block at {first[x]}'))
                else:
                    first[x] = h
    for p in pools:
        n, top, inpool = p['node'], p.get('h'), set(p.get('ids') or [])
        if not isinstance(top, int) or not inpool:
            continue
        for h, r in chain_at(blocks, n, p.get('t_ms')).items():
            if h <= top - pool_lag:
                stale = inpool.intersection(txids(r['block']))
                if stale:
                    x = sorted(stale)[0]
                    v['pool'].append((n, h, r['id'], f'transaction {x[:12]} still in the pool at full height {top}'))
    if len(nodes) > 1:
        lowest = min(max(ch) for ch in finals.values() if ch)
        for h in range(1, lowest - agree_depth + 1):
            ids = {n: finals[n][h]['id'] for n in nodes if h in finals[n]}
            if len(set(ids.values())) > 1:
                v['agree'].append((','.join(sorted(ids)), h, '', 'held ' + ' '.join(f'{n}={i[:12]}' for n, i in sorted(ids.items()))))
    seen = set()
    for cmd in contracts:
        name = 'contract:' + os.path.basename(shlex.split(cmd)[0])
        v.setdefault(name, [])
        for n in nodes:
            for h, r in sorted(finals[n].items()):
                if (cmd, r['id']) in seen:
                    continue
                seen.add((cmd, r['id']))
                env = dict(os.environ, BLOCK_NODE=n, BLOCK_HEIGHT=str(h), BLOCK_ID=r['id'])
                try:
                    p = subprocess.run(shlex.split(cmd), input=json.dumps(r['block']), env=env, capture_output=True,
                                       text=True, timeout=timeout)
                    rc, out = p.returncode, (p.stdout.strip() or p.stderr.strip())
                except (OSError, subprocess.TimeoutExpired) as e:
                    rc, out = -1, f'could not run: {e}'
                if rc != 0:
                    v[name].append((n, h, r['id'], (out.splitlines() or [f'exit {rc}'])[0][:200]))
    return dict(v), nodes


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('blocks')
    ap.add_argument('--contract', action='append', default=[])
    ap.add_argument('--agree-depth', type=int, default=3)
    ap.add_argument('--pool-lag', type=int, default=1)
    ap.add_argument('--max-report', type=int, default=5)
    ap.add_argument('--json')
    a = ap.parse_args(argv)
    blocks, pools = load(a.blocks) if os.path.exists(a.blocks) else ([], [])
    if not blocks:
        print(f'INVARIANTS: NO-INPUT (no block records in {a.blocks})')
        return 2
    v, nodes = check(blocks, pools, a.contract, a.agree_depth, a.pool_lag)
    names = ['link', 'body', 'once', 'pool', 'agree'] + [k for k in v if k.startswith('contract:')]
    total = sum(len(v.get(k, [])) for k in names)
    for k in names:
        for n, h, i, why in v.get(k, [])[:a.max_report]:
            print(f"{k} {n}@{h}{' ' + i[:12] if i else ''}: {why}")
        if len(v.get(k, [])) > a.max_report:
            print(f'{k}: ... {len(v[k]) - a.max_report} more')
    distinct = len({r['id'] for r in blocks})
    if total:
        print(f'INVARIANTS: VIOLATED total={total} ' + ' '.join(f'{k}={len(v.get(k, []))}' for k in names))
    else:
        print(f"INVARIANTS: OK blocks={distinct} nodes={len(nodes)} pools={len(pools)} checks={','.join(names)}")
    if a.json:
        with open(a.json, 'w') as f:
            json.dump({'blocks': distinct, 'nodes': nodes, 'pools': len(pools), 'checks': names,
                       'violations': {k: [dict(node=n, h=h, id=i, reason=w) for n, h, i, w in v.get(k, [])] for k in names}},
                      f, indent=1)
    return 1 if total else 0


if __name__ == '__main__':
    sys.exit(main())
